import AppKit
import SwiftUI
import SafarierCore
import SafarierNetwork
import SafarierWebKit

enum RunState {
    case stopped
    /// 已经起了 Runner 进程，还没拿到 profile 锁。
    case starting
    case running
}

/// profile 的出站：直连、独立代理，或订阅节点（启动时经 sing-box 转成本地 SOCKS5）。
enum ProxyBinding {
    case direct
    case custom
    case proxy(ProxySettings)
    /// proxyID 指向的代理已经被删除。
    case missing(UUID)
    case node(Subscription, SubscriptionNode)
    /// 绑定的订阅被删了，或刷新后没有这个名字的节点了。
    case missingNode(subscription: String?, node: String)
}

/// 图形管理器的状态。数据都在 SafarierWorkspace 的 JSON 里，这里只是读进来的副本；
/// 命令行在别处改了数据，窗口回到前台时会重新读。
@MainActor
final class ManagerModel: ObservableObject {
    enum Selection: Hashable {
        case profile(UUID)
        case subscription(UUID)
        case proxy(UUID)
    }

    enum Sheet: Identifiable {
        case newProfile
        case editProfile(Profile)
        case newSubscription
        case newProxy
        case editProxy(ProxySettings)

        var id: String {
            switch self {
            case .newProfile: return "new-profile"
            case .editProfile(let profile): return "edit-\(profile.id.uuidString)"
            case .newSubscription: return "new-subscription"
            case .newProxy: return "new-proxy"
            case .editProxy(let proxy): return "edit-proxy-\(proxy.id.uuidString)"
            }
        }
    }

    enum Confirmation {
        case deleteProfile(Profile)
        case purgeProfile(Profile)
        case deleteSubscription(Subscription)
        case deleteProxy(ProxySettings)
    }

    struct Message: Identifiable {
        let id = UUID()
        var title: String
        var detail: String
    }

    let workspace: SafarierWorkspace
    private let credentials: any CredentialStore

    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var proxies: [ProxySettings] = []
    @Published private(set) var subscriptions: [Subscription] = []
    @Published private(set) var running: Set<UUID> = []
    @Published private(set) var starting: Set<UUID> = []
    /// 正在拉取的订阅。
    @Published private(set) var refreshing: Set<UUID> = []
    /// 正在清理网站数据的 profile。
    @Published private(set) var purging: Set<UUID> = []
    @Published var selection: Selection?
    @Published var sheet: Sheet?
    @Published var confirmation: Confirmation?
    @Published var message: Message?

    private var monitor: Timer?
    private var activationObserver: NSObjectProtocol?

    init(workspace: SafarierWorkspace, credentials: any CredentialStore = KeychainCredentialStore()) {
        self.workspace = workspace
        self.credentials = credentials
        reload()
        selection = profiles.first.map { .profile($0.id) } ?? proxies.first.map { .proxy($0.id) } ?? subscriptions.first.map { .subscription($0.id) }
    }

    // MARK: - 读取

    func reload() {
        do {
            let profiles = try workspace.profiles.all()
            let proxies = try workspace.proxies.all()
            let subscriptions = try workspace.subscriptions.all()
            if profiles != self.profiles { self.profiles = profiles }
            if proxies != self.proxies { self.proxies = proxies }
            if subscriptions != self.subscriptions { self.subscriptions = subscriptions }
        } catch {
            report("读取数据失败", error)
        }
        refreshRunningState()
        switch selection {
        case .profile(let id) where profile(id) == nil: selection = nil
        case .subscription(let id) where subscription(id) == nil: selection = nil
        case .proxy(let id) where proxy(id) == nil: selection = nil
        default: break
        }
    }

    /// Runner 是独立进程，状态只能看锁：定时轮询，回到前台时顺便重读数据。
    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRunningState() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func refreshRunningState() {
        let now = Set(profiles.map(\.id).filter(workspace.isRunning))
        if now != running { running = now }
        if !starting.isDisjoint(with: now) { starting.subtract(now) }
        // Runner 被 SIGKILL 或崩溃时留下的 sing-box：没有 Runner 在跑的 profile 才清理。
        for profile in profiles where !now.contains(profile.id) && !starting.contains(profile.id) {
            SingboxProcessManager.reapOrphanIfIdle(profileID: profile.id, workspace: workspace)
        }
    }

    /// 绑定了这个订阅里某个节点的环境。
    func profiles(using subscription: Subscription) -> [Profile] {
        profiles.filter { $0.subscriptionID == subscription.id }
    }

    func profile(_ id: UUID) -> Profile? { profiles.first { $0.id == id } }
    func subscription(_ id: UUID) -> Subscription? { subscriptions.first { $0.id == id } }
    func proxy(_ id: UUID) -> ProxySettings? { proxies.first { $0.id == id } }

    func profiles(using proxy: ProxySettings) -> [Profile] {
        profiles.filter { $0.proxyID == proxy.id }
    }

    /// 空密码表示保留已有密码；关闭认证才删除 Keychain 项。
    func saveProxy(_ draft: ProxySettings, password: String?, isNew: Bool) throws {
        var proxy = draft
        proxy.name = proxy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        proxy.host = proxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
        proxy.username = proxy.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proxy.name.isEmpty else { throw ProxyManagementError.emptyName }
        if proxy.username?.isEmpty == true { throw ProxyManagementError.emptyUsername }
        try proxy.validate()
        let previous = try credentials.password(forKey: proxy.credentialKey)
        let next = proxy.username == nil ? nil : password ?? previous
        if proxy.username != nil, next?.isEmpty != false { throw ProxyManagementError.missingPassword }
        try withProxyPassword(next, previous: previous, key: proxy.credentialKey) {
            if isNew { try workspace.proxies.insert(proxy) }
            else { try workspace.proxies.update(proxy) }
        }
        reload()
        selection = .proxy(proxy.id)
    }

    func deleteProxy(_ proxy: ProxySettings) throws {
        // 使用最新磁盘记录，避免侧边栏尚未刷新时删除仍被环境引用的代理。
        let users = try workspace.profiles.all().filter { $0.proxyID == proxy.id }
        guard users.isEmpty else { throw ProxyManagementError.inUse(users.map(\.name)) }
        let previous = try credentials.password(forKey: proxy.credentialKey)
        try withProxyPassword(nil, previous: previous, key: proxy.credentialKey) {
            _ = try workspace.proxies.delete(id: proxy.id)
        }
        reload()
    }

    /// 元数据保存失败时恢复原凭据，不能留下“旧配置 + 新密码”。
    private func withProxyPassword(_ password: String?, previous: String?, key: String, write: () throws -> Void) throws {
        func set(_ value: String?) throws {
            if let value { try credentials.setPassword(value, forKey: key) }
            else { try credentials.removePassword(forKey: key) }
        }
        if password != previous { try set(password) }
        do {
            try write()
        } catch {
            let writeError = error
            if password != previous {
                do { try set(previous) }
                catch { throw ProxyManagementError.credentialRollbackFailed }
            }
            throw writeError
        }
    }

    var selectedProfile: Profile? {
        guard case .profile(let id) = selection else { return nil }
        return profile(id)
    }

    func runState(_ id: UUID) -> RunState {
        if running.contains(id) { return .running }
        return starting.contains(id) ? .starting : .stopped
    }

    func proxyBinding(for profile: Profile) -> ProxyBinding {
        if profile.customOutboundJSON != nil { return .custom }
        if let subscriptionID = profile.subscriptionID {
            let name = profile.nodeName ?? ""
            guard let subscription = subscription(subscriptionID) else { return .missingNode(subscription: nil, node: name) }
            guard let node = subscription.nodes.first(where: { $0.name == name }) else {
                return .missingNode(subscription: subscription.name, node: name)
            }
            return .node(subscription, node)
        }
        guard let id = profile.proxyID else { return .direct }
        return proxies.first { $0.id == id }.map(ProxyBinding.proxy) ?? .missing(id)
    }

    // MARK: - Runner

    func launch(_ profile: Profile) {
        guard runState(profile.id) == .stopped else { return }
        // Runner 找不到 sing-box 也会失败退出，这里先拦下来，提示更直接。
        let singbox = SingboxProcessManager.defaultExecutableURL
        if profile.subscriptionID != nil || profile.customOutboundJSON != nil, !FileManager.default.isExecutableFile(atPath: singbox.path) {
            report("无法启动「\(profile.name)」", SingboxProcessError.executableNotFound(singbox))
            return
        }
        let logURL = workspace.runnerLogURL(for: profile.id)
        let logOffset = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? UInt64) ?? 0
        let spawner = FoundationProcessSpawner { [weak self] exit in
            Task { @MainActor in
                self?.runnerExited(profile, exit, logURL: logURL, logOffset: logOffset)
            }
        }
        do {
            try workspace.launch(profile, launcher: RunnerLauncher(spawner: spawner, logDirectory: workspace.logsDirectory))
            starting.insert(profile.id)
            // 进程活着却一直没拿到锁（卡住）时，别让按钮永远停在"正在启动"。
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.starting.remove(profile.id)
            }
        } catch {
            report("无法启动「\(profile.name)」", error)
        }
    }

    private func runnerExited(_ profile: Profile, _ exit: ProcessExit, logURL: URL, logOffset: UInt64) {
        starting.remove(profile.id)
        refreshRunningState()
        guard exit.isFailure else { return }
        let reason = exit.uncaughtSignal ? "Runner 被信号 \(exit.status) 结束。" : "Runner 退出码 \(exit.status)。"
        let detail = [reason, Self.logTail(logURL, from: logOffset), "日志：\(logURL.path)"].compactMap { $0 }
        message = Message(title: "「\(profile.name)」启动失败或异常退出", detail: detail.joined(separator: "\n\n"))
    }

    /// 本次启动之后新写入日志的最后几行。
    private static func logTail(_ url: URL, from offset: UInt64, maxLines: Int = 12) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").suffix(maxLines)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func bringToFront(_ profile: Profile) {
        guard let pid = workspace.runnerPID(profile.id),
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
    }

    /// 和在 Runner 里按 ⌘Q 一样，正常退出、释放锁。
    func stop(_ profile: Profile) {
        guard let pid = workspace.runnerPID(profile.id) else { return }
        if let app = NSRunningApplication(processIdentifier: pid), app.terminate() { return }
        kill(pid, SIGTERM)
    }

    // MARK: - profile

    /// 校验期间不修改磁盘记录；失败时旧配置仍然完整保留。
    func saveValidated(_ profile: Profile, isNew: Bool, executableURL: URL = SingboxProcessManager.defaultExecutableURL) async throws {
        try profile.validate()
        var checkedProfile = profile
        if let json = profile.customOutboundJSON {
            checkedProfile.customOutboundJSON = try await Task.detached {
                try CustomOutbound.checked(json, executableURL: executableURL)
            }.value
        }
        try save(checkedProfile, isNew: isNew)
    }

    func save(_ profile: Profile, isNew: Bool) throws {
        if isNew {
            try workspace.profiles.insert(profile)
        } else {
            try workspace.profiles.update(profile)
        }
        reload()
        selection = .profile(profile.id)
    }

    /// 复制环境：设置全部照抄、换新 ID，名字加「副本」后缀；网站数据（Cookie、登录状态）不复制。
    @discardableResult
    func duplicate(_ profile: Profile) -> Profile? {
        let name = Profile.duplicateName(for: profile.name, existing: Set(profiles.map(\.name)))
        let copy = profile.duplicated(name: name)
        do {
            try workspace.profiles.insert(copy)
        } catch {
            report("复制「\(profile.name)」失败", error)
            return nil
        }
        reload()
        selection = .profile(copy.id)
        return copy
    }

    /// 先清数据再删记录：清除失败时记录还在，可以重试（与命令行 `profile delete --purge-data` 一致）。
    func delete(_ profile: Profile, purgeData: Bool) {
        guard runState(profile.id) == .stopped, !purging.contains(profile.id) else { return }
        Task {
            do {
                if purgeData, profile.mode == .persistent {
                    purging.insert(profile.id)
                    defer { purging.remove(profile.id) }
                    try await DataStoreManager().removePersistentData(for: profile.id)
                }
                try workspace.profiles.delete(id: profile.id)
                workspace.removeRunnerArtifacts(for: profile.id)
                reload()
            } catch {
                report("删除「\(profile.name)」失败", error)
            }
        }
    }

    func purgeData(_ profile: Profile) {
        guard profile.mode == .persistent, runState(profile.id) == .stopped, !purging.contains(profile.id) else { return }
        purging.insert(profile.id)
        Task {
            defer { purging.remove(profile.id) }
            do {
                try await DataStoreManager().removePersistentData(for: profile.id)
                try? FileManager.default.removeItem(at: workspace.historyURL(for: profile.id))
                message = Message(title: "已清理「\(profile.name)」", detail: "Cookie、登录状态、本地存储、缓存和浏览历史都已删除，环境配置保留。")
            } catch {
                report("清理「\(profile.name)」的数据失败", error)
            }
        }
    }

    // MARK: - 订阅

    /// 与命令行 `sub add` 一致：订阅网址先拉取成功再保存；直接粘贴的节点链接先解析成功，原文存成本机文件，订阅地址指向它。
    /// 混着不支持的协议（hysteria2 等）时导入其余节点，并提示跳过了哪些。
    func addSubscription(name: String, input: String) async throws {
        let id = UUID()
        let url: URL
        let result: SubscriptionParseResult
        if let remote = InlineSubscription.subscriptionURL(from: input) {
            url = remote
            result = try await SubscriptionFetcher().fetchResult(from: remote)
        } else {
            let stored = try InlineSubscription.store(input, id: id, in: workspace.root)
            url = stored.url
            result = stored.result
        }
        let subscription = Subscription(id: id, name: name, url: url, updatedAt: Date(), nodes: result.nodes)
        do {
            try workspace.subscriptions.insert(subscription)
        } catch {
            InlineSubscription.remove(url, in: workspace.root)
            throw error
        }
        reload()
        selection = .subscription(subscription.id)
        if result.skippedCount > 0 {
            message = Message(title: "已添加「\(name)」", detail: DisplayText.importSummary(result))
        }
    }

    /// 订阅是不是直接粘贴的节点链接（保存在本机）。
    func isInline(_ subscription: Subscription) -> Bool {
        InlineSubscription.isInline(subscription.url, in: workspace.root)
    }

    func refresh(_ subscription: Subscription) {
        guard !refreshing.contains(subscription.id) else { return }
        refreshing.insert(subscription.id)
        Task {
            defer { refreshing.remove(subscription.id) }
            do {
                let nodes = try await SubscriptionFetcher().fetch(from: subscription.url)
                // 拉取期间记录可能在别处被改动或删除：以文件里的最新记录为准，只换节点。
                guard var latest = try workspace.subscriptions.record(id: subscription.id) else { return }
                // 订阅这次返回的内容里没有节点（服务器偶尔返回空内容）：不拿空列表覆盖已有节点，否则绑定它们的环境全部失效。
                if nodes.isEmpty, !latest.nodes.isEmpty {
                    message = Message(title: "刷新「\(subscription.name)」没有拿到节点", detail: "订阅这次返回的内容里没有可用节点，保留原来的 \(latest.nodes.count) 个节点。")
                    return
                }
                latest.nodes = nodes
                latest.updatedAt = Date()
                try workspace.subscriptions.update(latest)
                reload()
            } catch {
                report("刷新「\(subscription.name)」失败", error)
            }
        }
    }

    func refreshAllSubscriptions() {
        subscriptions.forEach(refresh)
    }

    func delete(_ subscription: Subscription) {
        let users = profiles(using: subscription)
        guard users.isEmpty else {
            message = Message(
                title: "订阅「\(subscription.name)」还在使用",
                detail: "这些环境绑定了它的节点：\(users.map(\.name).joined(separator: "、"))。先在环境里换掉出站再删除。"
            )
            return
        }
        do {
            try workspace.subscriptions.delete(id: subscription.id)
            InlineSubscription.remove(subscription.url, in: workspace.root)
            reload()
        } catch {
            report("删除订阅「\(subscription.name)」失败", error)
        }
    }

    private func report(_ title: String, _ error: Error) {
        message = Message(title: title, detail: DisplayText.describe(error))
    }
}
