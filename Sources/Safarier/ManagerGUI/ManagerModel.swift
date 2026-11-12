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
    enum ProxyTestState: Equatable {
        case queued
        case running
        case success(ProxyConnectionResult)
        case failure(String)
    }

    struct NodeTestKey: Hashable {
        let subscriptionID: UUID
        let nodeID: UUID
    }

    enum Selection: Hashable {
        case profile(UUID)
        case subscription(UUID)
        case proxy(UUID)
    }

    enum Sheet: Identifiable {
        case newProfile
        case newSubscription
        case newProxy
        case editProxy(ProxySettings)

        var id: String {
            switch self {
            case .newProfile: return "new-profile"
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
    private let proxyTester: ProxyConnectionTester.Test
    private var proxyTestTasks: [UUID: Task<Void, Never>] = [:]
    @Published private(set) var proxyTests: [UUID: ProxyTestState] = [:]
    private let nodeBatchTester: ProxyConnectionTester.NodeBatchTest
    private var nodeTestTasks: [UUID: Task<Void, Never>] = [:]
    private var nodeTestQueue: [UUID: [SubscriptionNode]] = [:]
    private var nodeTestRuns: [UUID: UUID] = [:]
    @Published private(set) var nodeTests: [NodeTestKey: ProxyTestState] = [:]

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

    /// 启动时静默检查到的新版本；`isUpdateBannerDismissed` 只隐藏本轮横幅。
    @Published var availableUpdate: ReleaseInfo?
    @Published var isUpdateBannerDismissed = false
    @Published var isInstallingUpdate = false
    @Published var updateStatusText: String?
    @Published var showingUpdateNotes: ReleaseInfo?

    private var profileEditors: [UUID: ProfileEditorState] = [:]

    func editor(for profile: Profile) -> ProfileEditorState {
        if let editor = profileEditors[profile.id] { return editor }
        let editor = ProfileEditorState(original: profile)
        profileEditors[profile.id] = editor
        return editor
    }

    private func requireSavedProfile(_ profile: Profile) -> Bool {
        guard let editor = profileEditors[profile.id], editor.hasChanges || editor.isSaving else { return true }
        message = Message(title: L10n.text("环境还有未保存的修改"), detail: L10n.text("请先在详情页保存或还原修改。"))
        return false
    }

    private var didCheckForUpdate = false
    private var orphanCleanupTask: Task<Void, Never>?
    private var monitor: Timer?
    private var activationObserver: NSObjectProtocol?

    init(workspace: SafarierWorkspace, credentials: any CredentialStore = KeychainCredentialStore(),
         proxyTester: @escaping ProxyConnectionTester.Test = { try await ProxyConnectionTester.check(proxy: $0, password: $1) },
         nodeTester: ProxyConnectionTester.NodeTest? = nil,
         nodeBatchTester: ProxyConnectionTester.NodeBatchTest? = nil) {
        self.workspace = workspace
        self.credentials = credentials
        self.proxyTester = proxyTester
        if let nodeBatchTester { self.nodeBatchTester = nodeBatchTester }
        else if let nodeTester {
            self.nodeBatchTester = { nodes, update in
                try await ProxyConnectionTester.checkConcurrently(nodes: nodes, using: nodeTester, update: update)
            }
        } else {
            self.nodeBatchTester = { try await ProxyConnectionTester.check(nodes: $0, update: $1) }
        }
        reload()
        selection = profiles.first.map { .profile($0.id) } ?? proxies.first.map { .proxy($0.id) } ?? subscriptions.first.map { .subscription($0.id) }
    }

    deinit {
        orphanCleanupTask?.cancel()
        for task in proxyTestTasks.values { task.cancel() }
        for task in nodeTestTasks.values { task.cancel() }
    }

    // MARK: - 读取

    func reload() {
        do {
            let profiles = try workspace.profiles.all()
            let proxies = try workspace.proxies.all()
            let subscriptions = try workspace.subscriptions.all()
            for (id, editor) in profileEditors {
                if let profile = profiles.first(where: { $0.id == id }) {
                    editor.receive(profile)
                } else {
                    profileEditors.removeValue(forKey: id)
                }
            }
            if profiles != self.profiles { self.profiles = profiles }
            if proxies != self.proxies {
                let previous = Dictionary(uniqueKeysWithValues: self.proxies.map { ($0.id, $0) })
                let current = Dictionary(uniqueKeysWithValues: proxies.map { ($0.id, $0) })
                let changed = Set(previous.keys).union(current.keys).filter { previous[$0] != current[$0] }
                // 前置变化也会改变出口代理的测试结果；只取消受影响的出口，不打断其它代理的测试。
                for id in changed { cancelProxyTest(id) }
                for exit in proxies where exit.upstream?.proxyID.map(changed.contains) == true { cancelProxyTest(exit.id) }
                self.proxies = proxies
            }
            if subscriptions != self.subscriptions {
                let previous = Dictionary(uniqueKeysWithValues: self.subscriptions.map { ($0.id, $0) })
                for old in self.subscriptions where subscriptions.first(where: { $0.id == old.id })?.nodes != old.nodes {
                    cancelNodeTests(subscriptionID: old.id)
                    nodeTests = nodeTests.filter { $0.key.subscriptionID != old.id }
                }
                for exit in proxies {
                    guard let id = exit.upstream?.subscriptionID else { continue }
                    if previous[id] != subscriptions.first(where: { $0.id == id }) { cancelProxyTest(exit.id) }
                }
                self.subscriptions = subscriptions
            }
        } catch {
            report(L10n.text("读取数据失败"), error)
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
        checkForUpdateOnLaunch()
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

    /// 启动后静默查一次；失败（断网、限流）不打扰用户。
    func checkForUpdateOnLaunch() {
        guard !didCheckForUpdate else { return }
        didCheckForUpdate = true
        let current = AboutAndUpdateController.currentVersion
        Task { @MainActor [weak self] in
            guard let status = try? await UpdateChecker.checkLatest(currentVersion: current),
                  case .updateAvailable(_, let latest) = status else { return }
            self?.availableUpdate = latest
        }
    }

    func installAvailableUpdate() {
        guard let release = availableUpdate, !isInstallingUpdate else { return }
        isInstallingUpdate = true
        updateStatusText = L10n.text("准备更新…")
        Task { @MainActor [weak self] in
            do {
                try await AboutAndUpdateController.installUpdateAndRelaunch(release) { text in
                    Task { @MainActor in self?.updateStatusText = text }
                }
                self?.updateStatusText = nil
            } catch {
                self?.updateStatusText = nil
                self?.message = .init(title: L10n.text("更新失败"), detail: DisplayText.describe(error))
            }
            self?.isInstallingUpdate = false
        }
    }

    func refreshRunningState() {
        // 后台清理也会暂时持有 profile 锁；管理器自己的锁不能当成运行中的 Runner。
        let now = Set(profiles.map(\.id).filter {
            workspace.isRunning($0) && workspace.runnerPID($0) != getpid()
        })
        if now != running { running = now }
        if !starting.isDisjoint(with: now) { starting.subtract(now) }
        guard orphanCleanupTask == nil else { return }
        let idle = profiles.map(\.id).filter { !now.contains($0) && !starting.contains($0) }
        guard !idle.isEmpty else { return }
        // SIGTERM 的等待最多两秒；连同拿锁和进程身份核验一起放到后台，同一时间只清理一批。
        orphanCleanupTask = Task.detached(priority: .utility) { [weak self, workspace] in
            for id in idle {
                guard !Task.isCancelled else { break }
                SingboxProcessManager.reapOrphanIfIdle(profileID: id, workspace: workspace)
            }
            await self?.orphanCleanupFinished()
        }
    }

    private func orphanCleanupFinished() {
        orphanCleanupTask = nil
    }

    func profile(_ id: UUID) -> Profile? { profiles.first { $0.id == id } }
    func subscription(_ id: UUID) -> Subscription? { subscriptions.first { $0.id == id } }
    func proxy(_ id: UUID) -> ProxySettings? { proxies.first { $0.id == id } }

    func profiles(using proxy: ProxySettings) -> [Profile] {
        let exits = Set(proxies.filter { $0.upstream?.proxyID == proxy.id }.map(\.id))
        return profiles.filter { $0.proxyID == proxy.id || $0.proxyID.map(exits.contains) == true }
    }

    func proxies(using proxy: ProxySettings) -> [ProxySettings] {
        proxies.filter { $0.upstream?.proxyID == proxy.id }
    }

    func proxies(using subscription: Subscription) -> [ProxySettings] {
        proxies.filter { $0.upstream?.subscriptionID == subscription.id }
    }

    func upstreamName(_ upstream: ProxyUpstream) -> String {
        switch upstream {
        case .proxy(let id): return proxy(id)?.name ?? L10n.text("前置代理已删除")
        case .node(let id, let name):
            guard let subscription = subscription(id) else { return L10n.text("前置订阅已删除") }
            return subscription.nodes.contains(where: { $0.name == name }) ? name : L10n.text("前置节点已失效：%@", name)
        case .custom: return L10n.text("自定义前置")
        }
    }

    func connectionPath(_ proxy: ProxySettings) -> String {
        proxy.upstream.map { L10n.text("%@ → %@ → 网站", upstreamName($0), proxy.name) }
            ?? L10n.text("%@ → 网站", proxy.name)
    }

    func testProxy(_ proxy: ProxySettings) {
        guard proxyTestTasks[proxy.id] == nil else { return }
        do {
            let records = try workspace.proxies.all()
            guard let current = records.first(where: { $0.id == proxy.id }) else { throw RepositoryError.notFound(proxy.id) }
            let chain = try ProxyChainBuilder.resolve(current, in: workspace, credentials: credentials)
            let password = current.username?.isEmpty == false ? try credentials.password(forKey: current.credentialKey) : nil
            if current.username?.isEmpty == false, password == nil { throw ProxyConnectionError.missingPassword }
            let tester = proxyTester
            proxyTests[current.id] = .running
            proxyTestTasks[current.id] = Task { @MainActor [weak self] in
                let outcome: ProxyTestState?
                do {
                    if let chain {
                        outcome = .success(try await ProxyConnectionTester.check(chain: chain, using: tester))
                    } else {
                        outcome = .success(try await tester(current, password))
                    }
                } catch is CancellationError {
                    outcome = nil
                } catch {
                    outcome = .failure(DisplayText.describe(error))
                }
                guard !Task.isCancelled, let self else { return }
                // 仅当前未取消的任务负责收尾；旧任务不能清掉后来启动的测试。
                defer { self.proxyTestTasks[current.id] = nil }
                // CLI 或其它窗口在测试中修改了出口或前置代理时，丢弃旧快照的结果。只读一次代理文件；
                // 前置直接与生成链路时捕获的快照比较，避免解析过程中刷新订阅后误用新节点作比较依据。
                // 不重新解析链路或读取钥匙串。
                let latest = try? self.workspace.proxies.all()
                guard latest?.first(where: { $0.id == current.id }) == current else {
                    self.proxyTests[current.id] = nil
                    return
                }
                if case .proxy(let entry) = chain?.upstream,
                   latest?.first(where: { $0.id == entry.id }) != entry {
                    self.proxyTests[current.id] = nil
                    return
                }
                if case .node(let subscriptionNode) = chain?.upstream, let id = current.upstream?.subscriptionID {
                    let latestNode = try? self.workspace.subscriptions.record(id: id)?.nodes.first {
                        $0.name == current.upstream?.nodeName
                    }
                    guard latestNode == subscriptionNode else {
                        self.proxyTests[current.id] = nil
                        return
                    }
                }
                self.proxyTests[current.id] = outcome
            }
        } catch {
            proxyTests[proxy.id] = .failure(DisplayText.describe(error))
        }
    }

    func cancelProxyTest(_ id: UUID) {
        proxyTestTasks.removeValue(forKey: id)?.cancel()
        proxyTests[id] = nil
    }

    func nodeTestState(subscriptionID: UUID, node: SubscriptionNode) -> ProxyTestState? {
        nodeTests[NodeTestKey(subscriptionID: subscriptionID, nodeID: node.id)]
    }

    func isTestingNodes(subscriptionID: UUID) -> Bool {
        nodeTests.contains { $0.key.subscriptionID == subscriptionID && ($0.value == .running || $0.value == .queued) }
    }

    /// 一次启动整批请求，完成一个就显示一个；打开节点选择器不会自动拨测。
    func testNodes(_ nodes: [SubscriptionNode], subscriptionID: UUID) {
        guard let current = try? workspace.subscriptions.record(id: subscriptionID) else { return }
        for node in nodes where current.nodes.contains(node) {
            let key = NodeTestKey(subscriptionID: subscriptionID, nodeID: node.id)
            guard nodeTests[key] != .running, nodeTests[key] != .queued else { continue }
            nodeTests[key] = .queued
            nodeTestQueue[subscriptionID, default: []].append(node)
        }
        startQueuedNodeTests()
    }

    func cancelNodeTests(subscriptionID: UUID) {
        nodeTestQueue[subscriptionID] = nil
        nodeTestRuns[subscriptionID] = nil
        // 等旧批次清理完再启动重试，避免连续取消累积后台辅助进程。
        nodeTestTasks[subscriptionID]?.cancel()
        nodeTests = nodeTests.filter {
            $0.key.subscriptionID != subscriptionID || ($0.value != .running && $0.value != .queued)
        }
        startQueuedNodeTests()
    }

    private func startQueuedNodeTests() {
        for subscriptionID in Array(nodeTestQueue.keys) where nodeTestTasks[subscriptionID] == nil {
            guard let nodes = nodeTestQueue.removeValue(forKey: subscriptionID), !nodes.isEmpty else { continue }
            let tester = nodeBatchTester
            let run = UUID()
            nodeTestRuns[subscriptionID] = run
            for node in nodes { nodeTests[NodeTestKey(subscriptionID: subscriptionID, nodeID: node.id)] = .running }
            nodeTestTasks[subscriptionID] = Task { @MainActor [weak self] in
                var failure: ProxyTestState?
                do {
                    try await tester(nodes) { [weak self] id, result in
                        await self?.receiveNodeTest(result, nodeID: id, nodes: nodes,
                                                    subscriptionID: subscriptionID, run: run)
                    }
                } catch is CancellationError { }
                catch { failure = .failure(DisplayText.describe(error)) }
                guard let self else { return }
                self.nodeTestTasks[subscriptionID] = nil
                if self.nodeTestRuns[subscriptionID] == run {
                    self.nodeTestRuns[subscriptionID] = nil
                    let latest = try? self.workspace.subscriptions.record(id: subscriptionID)
                    for node in nodes {
                        let key = NodeTestKey(subscriptionID: subscriptionID, nodeID: node.id)
                        if self.nodeTests[key] == .running {
                            self.nodeTests[key] = latest?.nodes.contains(node) == true ? failure : nil
                        }
                    }
                }
                self.startQueuedNodeTests()
            }
        }
    }

    private func receiveNodeTest(_ result: Result<ProxyConnectionResult, Error>, nodeID: UUID,
                                 nodes: [SubscriptionNode], subscriptionID: UUID, run: UUID) {
        guard nodeTestRuns[subscriptionID] == run, let node = nodes.first(where: { $0.id == nodeID }) else { return }
        let key = NodeTestKey(subscriptionID: subscriptionID, nodeID: nodeID)
        guard nodeTests[key] == .running else { return }
        // 刷新、删除或外部 CLI 修改后，旧节点的延迟不能覆盖新节点。
        let latest = try? workspace.subscriptions.record(id: subscriptionID)
        guard latest?.nodes.contains(node) == true else { nodeTests[key] = nil; return }
        switch result {
        case .success(let value): nodeTests[key] = .success(value)
        case .failure(let error): nodeTests[key] = .failure(DisplayText.describe(error))
        }
    }

    /// 空密码表示保留已有密码；关闭认证才删除 Keychain 项。
    func saveProxyValidated(_ draft: ProxySettings, password: String?, isNew: Bool) async throws {
        var checked = draft
        if case .custom(let json) = draft.upstream {
            let normalized = try await Task.detached { try CustomOutbound.checked(json) }.value
            checked.upstream = .custom(normalized)
        }
        try saveProxy(checked, password: password, isNew: isNew)
    }

    func saveProxy(_ draft: ProxySettings, password: String?, isNew: Bool) throws {
        var proxy = draft
        proxy.name = proxy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        proxy.host = proxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
        proxy.username = proxy.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proxy.name.isEmpty else { throw ProxyManagementError.emptyName }
        if proxy.username?.isEmpty == true { throw ProxyManagementError.emptyUsername }
        try workspace.validateProxyChain(proxy)
        if case .custom(let json) = proxy.upstream {
            proxy.upstream = .custom(try CustomOutbound.encoded(CustomOutbound.parse(json)))
        }
        let previous = try credentials.password(forKey: proxy.credentialKey)
        let next = proxy.username == nil ? nil : password ?? previous
        if proxy.username != nil, next?.isEmpty != false { throw ProxyManagementError.missingPassword }
        try withProxyPassword(next, previous: previous, key: proxy.credentialKey) {
            if isNew { try workspace.insertProxy(proxy) }
            else { try workspace.updateProxy(proxy) }
        }
        cancelProxyTest(proxy.id)
        // 只改密码时记录不变，reload 看不出来；以它为前置的出口要在这里取消。
        for exit in proxies where exit.upstream?.proxyID == proxy.id { cancelProxyTest(exit.id) }
        reload()
        selection = .proxy(proxy.id)
    }

    func deleteProxy(_ proxy: ProxySettings) throws {
        // 使用最新磁盘记录，避免侧边栏尚未刷新时删除仍被环境引用的代理。
        let users = try workspace.profiles.all().filter { $0.proxyID == proxy.id }
        guard users.isEmpty else { throw ProxyManagementError.inUse(users.map(\.name)) }
        let exits = try workspace.proxies(usingProxyID: proxy.id)
        guard exits.isEmpty else { throw ProxyManagementError.usedAsUpstream(exits.map(\.name)) }
        let previous = try credentials.password(forKey: proxy.credentialKey)
        try withProxyPassword(nil, previous: previous, key: proxy.credentialKey) {
            // 初次检查后其它进程仍可能保存引用；必须在删除的同一把文件锁内重新检查。
            _ = try workspace.proxies.delete(id: proxy.id) { records in
                let exits = records.filter { $0.upstream?.proxyID == proxy.id }
                guard exits.isEmpty else { throw ProxyManagementError.usedAsUpstream(exits.map(\.name)) }
            }
        }
        cancelProxyTest(proxy.id)
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
        guard requireSavedProfile(profile), runState(profile.id) == .stopped else { return }
        starting.insert(profile.id)
        if let cleanup = orphanCleanupTask {
            // 清理持锁期间仍允许点击启动；异步等锁释放，避免 Runner 因竞争锁而启动失败。
            Task { [weak self] in
                await cleanup.value
                guard let self else { return }
                guard let current = self.profile(profile.id) else {
                    self.starting.remove(profile.id)
                    return
                }
                self.launchRunner(current)
            }
        } else {
            launchRunner(profile)
        }
    }

    private func launchRunner(_ profile: Profile) {
        // 清理等待期间仍可编辑配置，真正启动前再次检查草稿。
        guard requireSavedProfile(profile) else {
            starting.remove(profile.id)
            return
        }
        // Runner 找不到 sing-box 也会失败退出，这里先拦下来，提示更直接。
        let singbox = SingboxProcessManager.defaultExecutableURL
        if profile.subscriptionID != nil || profile.customOutboundJSON != nil || profile.proxyID.flatMap(proxy)?.upstream != nil,
           !FileManager.default.isExecutableFile(atPath: singbox.path) {
            starting.remove(profile.id)
            report(L10n.text("无法启动「%@」", profile.name), SingboxProcessError.executableNotFound(singbox))
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
            starting.remove(profile.id)
            report(L10n.text("无法启动「%@」", profile.name), error)
        }
    }

    private func runnerExited(_ profile: Profile, _ exit: ProcessExit, logURL: URL, logOffset: UInt64) {
        starting.remove(profile.id)
        refreshRunningState()
        guard exit.isFailure else { return }
        let reason = exit.uncaughtSignal
            ? L10n.text("Runner 被信号 %lld 结束。", Int(exit.status))
            : L10n.text("Runner 退出码 %lld。", Int(exit.status))
        let detail = [reason, Self.logTail(logURL, from: logOffset), L10n.text("日志：%@", logURL.path)].compactMap { $0 }
        message = Message(title: L10n.text("「%@」启动失败或异常退出", profile.name), detail: detail.joined(separator: "\n\n"))
    }

    /// 只读本次启动后的末尾 64 KiB，避免异常退出时把整份日志搬进主线程。
    static func logTail(_ url: URL, from offset: UInt64, maxLines: Int = 12) -> String? {
        guard maxLines > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let limit: UInt64 = 64 * 1024
        guard let end = try? handle.seekToEnd(), end > offset else { return nil }
        let start = max(offset, end > limit ? end - limit : 0)
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(end - start)) else { return nil }
        // 截断点可能落在 UTF-8 字符中间；保留后面的有效文本，而不是丢掉全部诊断。
        var bytes = data[...]
        if start > offset, let newline = bytes.firstIndex(of: 0x0A) {
            bytes = bytes[bytes.index(after: newline)...]
        }
        let text = String(decoding: bytes, as: UTF8.self)
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
        guard let pid = workspace.runnerPID(profile.id), pid != getpid() else { return }
        if let app = NSRunningApplication(processIdentifier: pid), app.terminate() { return }
        kill(pid, SIGTERM)
    }

    // MARK: - profile

    /// 校验期间不修改磁盘记录；失败时旧配置仍然完整保留。
    func saveValidated(_ profile: Profile, isNew: Bool, executableURL: URL = SingboxProcessManager.defaultExecutableURL,
                       expectedProfile: Profile? = nil, selectSavedProfile: Bool = true) async throws {
        try profile.validate()
        var checkedProfile = profile
        if let json = profile.customOutboundJSON {
            checkedProfile.customOutboundJSON = try await Task.detached {
                try CustomOutbound.checked(json, executableURL: executableURL)
            }.value
        }
        if let expectedProfile, try workspace.profiles.record(id: profile.id) != expectedProfile {
            throw ProfileEditorError.changedExternally
        }
        try save(checkedProfile, isNew: isNew, selectSavedProfile: selectSavedProfile)
    }

    func save(_ profile: Profile, isNew: Bool, selectSavedProfile: Bool = true) throws {
        if isNew {
            try workspace.profiles.insert(profile)
        } else {
            try workspace.profiles.update(profile)
        }
        reload()
        if selectSavedProfile { selection = .profile(profile.id) }
    }

    /// 复制环境：设置全部照抄、换新 ID，名字加「副本」后缀；网站数据（Cookie、登录状态）不复制。
    @discardableResult
    func duplicate(_ profile: Profile) -> Profile? {
        guard requireSavedProfile(profile) else { return nil }
        let name = Profile.duplicateName(for: profile.name, existing: Set(profiles.map(\.name)))
        let copy = profile.duplicated(name: name)
        do {
            try workspace.profiles.insert(copy)
        } catch {
            report(L10n.text("复制「%@」失败", profile.name), error)
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
                report(L10n.text("删除「%@」失败", profile.name), error)
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
                message = Message(title: L10n.text("已清理「%@」", profile.name), detail: L10n.text("Cookie、登录状态、本地存储、缓存和浏览历史都已删除，环境配置保留。"))
            } catch {
                report(L10n.text("清理「%@」的数据失败", profile.name), error)
            }
        }
    }

    // MARK: - 订阅

    /// 与命令行 `sub add` 一致：订阅网址先拉取成功再保存；直接粘贴的节点链接先解析成功，原文存成本机文件，订阅地址指向它。
    /// 混着不支持的协议时导入其余节点，并提示跳过了哪些。
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
            message = Message(title: L10n.text("已添加「%@」", name), detail: DisplayText.importSummary(result))
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
                let result = try await SubscriptionFetcher().fetchResult(from: subscription.url)
                let nodes = result.nodes
                // 拉取期间记录可能在别处被改动或删除：以文件里的最新记录为准，只换节点。
                guard var latest = try workspace.subscriptions.record(id: subscription.id) else { return }
                // 订阅这次返回的内容里没有节点（服务器偶尔返回空内容）：不拿空列表覆盖已有节点，否则绑定它们的环境全部失效。
                if nodes.isEmpty, !latest.nodes.isEmpty {
                    message = Message(title: L10n.text("刷新「%@」没有拿到节点", subscription.name),
                                      detail: L10n.text("订阅这次返回的内容里没有可用节点，保留原来的 %lld 个节点。", latest.nodes.count))
                    return
                }
                latest.nodes = nodes
                latest.updatedAt = Date()
                try workspace.subscriptions.update(latest)
                reload()
                if result.skippedCount > 0 {
                    message = Message(title: L10n.text("已更新「%@」", latest.name), detail: DisplayText.importSummary(result))
                }
            } catch {
                report(L10n.text("刷新「%@」失败", subscription.name), error)
            }
        }
    }

    func refreshAllSubscriptions() {
        subscriptions.forEach(refresh)
    }

    func delete(_ subscription: Subscription) {
        do {
            let users = try workspace.profiles.all().filter { $0.subscriptionID == subscription.id }
            let exits = try workspace.proxies(usingSubscriptionID: subscription.id)
            guard users.isEmpty, exits.isEmpty else {
                message = Message(
                    title: L10n.text("订阅「%@」还在使用", subscription.name),
                    detail: L10n.text("以下环境或代理仍引用此订阅：%@。请先更换出站或前置连接。",
                                      (users.map(\.name) + exits.map(\.name)).joined(separator: L10n.text("、")))
                )
                return
            }
            try workspace.subscriptions.delete(id: subscription.id)
            InlineSubscription.remove(subscription.url, in: workspace.root)
            reload()
        } catch {
            report(L10n.text("删除订阅「%@」失败", subscription.name), error)
        }
    }

    private func report(_ title: String, _ error: Error) {
        message = Message(title: title, detail: DisplayText.describe(error))
    }
}
