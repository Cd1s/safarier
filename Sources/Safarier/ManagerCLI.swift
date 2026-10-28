import Foundation
import SafarierCore
import SafarierNetwork
import SafarierWebKit

/// 命令行 Manager。图形管理器（ManagerGUI）和这里共用 SafarierCore 的仓库和 `SafarierWorkspace.launch`。
@MainActor
enum ManagerCLI {
    static let usage = """
    用法：
      safarier profile list
      safarier profile create --name NAME [--mode persistent|ephemeral] [--lang proxy|system|en-US,en] [--tz proxy|system|America/Los_Angeles] [--url https://example.com] [--proxy PROXY_ID | --sub SUBSCRIPTION_ID --node NODE_NAME] [--device MODEL] [--notes TEXT] [--spi default|none|all|afp,tz,webrtc,safari,webgpu,fontlist]
      safarier profile update PROFILE_ID [--name NAME] [--lang proxy|system|en-US,en] [--tz proxy|system|ZONE] [--url URL|none] [--proxy PROXY_ID|none | --sub SUBSCRIPTION_ID --node NODE_NAME | --node none] [--device MODEL|none] [--notes TEXT] [--spi default|none|all|afp,tz,webrtc,safari,webgpu,fontlist]
      safarier profile clone PROFILE_ID [--name NAME]
      safarier profile delete PROFILE_ID [--purge-data]
      safarier proxy list
      safarier proxy add --name NAME --kind socks5|httpConnect --host HOST --port PORT [--username USER] [--password-stdin]
      safarier proxy delete PROXY_ID
      safarier sub add --name NAME --url URL|节点链接|-
      safarier sub list
      safarier sub update [SUBSCRIPTION_ID]
      safarier sub nodes SUBSCRIPTION_ID
      safarier device list
      safarier ext list
      safarier ext add PATH [--profile PROFILE_ID]
      safarier ext remove NAME
      safarier launch PROFILE_ID [--url URL] [--spi LIST]
      safarier probe PROFILE_ID [--url URL] [--spi LIST]
    --sub/--node：出站走订阅里的节点（按节点名匹配，名字带空格时加引号）；启动时自动起 sing-box 转成本地 SOCKS5。
           和 --proxy 二选一：设了一个就清掉另一个。
    --lang/--tz：proxy（或 auto）= 跟随代理，每次启动按代理出口 IP 的国家自动设置；system（或 none）= 跟随系统；
           其它值是语言标签（逗号分隔）或时区标识。
    --device：模拟机型（见 device list），决定浏览窗口的默认视口尺寸、比例和屏幕色域 / HDR。
    --spi：系统 WebKit 原生隐私能力。afp=高级隐私保护（反指纹），tz=引擎层时区同步，webrtc=关闭 WebRTC，
           safari=打开 Safari 专有接口（ApplePaySession、PushManager、navigator.mediaDevices），并像 Safari 一样关闭用户安装字体，
           webgpu=打开 WebGPU（真 Safari 在 macOS 15 上没有，打开后和真 Safari 不一致），
           fontlist=按 Profile 语言收窄网页能按名字用的字体（只留系统字体；英文环境隐藏苹方、冬青黑体、宋体等中日韩字体）。
           新建环境默认 default（afp,tz,safari,fontlist）；all 是全部六项。launch/probe 上的 --spi 只覆盖这一次运行。
    sub add --url：订阅网址（http / https / file），或直接给节点链接（ss:// ss2022:// vless:// vmess:// trojan:// anytls:// socks://，
           多条用换行分隔，也可以是 Base64；- 表示从标准输入读）。直接给的链接保存在元数据目录的 subscriptions-inline/ 里，
           sub update 时重新读它。订阅里 hysteria2 等暂不支持的协议会跳过，其余节点照常导入。
    profile clone：复制全部设置到新环境（新 ID，不复制 Cookie 等网站数据），默认名字加「副本」。
    环境变量 SAFARIER_HOME 可覆盖元数据目录（默认 ~/Library/Application Support/Safarier）。
    """

    static func run(_ arguments: [String]) -> Int32 {
        do {
            let workspace = try SafarierWorkspace.default()
            switch (arguments.first, arguments.dropFirst().first) {
            case ("profile", "list"): return try listProfiles(workspace)
            case ("profile", "create"): return try createProfile(workspace, try ParsedArguments(arguments.dropFirst(2)))
            case ("profile", "update"): return try updateProfile(workspace, try ParsedArguments(arguments.dropFirst(2)))
            case ("profile", "clone"): return try cloneProfile(workspace, try ParsedArguments(arguments.dropFirst(2)))
            case ("profile", "delete"): return try deleteProfile(workspace, try ParsedArguments(arguments.dropFirst(2), flags: ["--purge-data"]))
            case ("proxy", "list"): return try listProxies(workspace)
            case ("proxy", "add"): return try addProxy(workspace, try ParsedArguments(arguments.dropFirst(2), flags: ["--password-stdin"]))
            case ("proxy", "delete"): return try deleteProxy(workspace, try ParsedArguments(arguments.dropFirst(2)))
            case ("sub", "add"): return try addSubscription(workspace, try ParsedArguments(arguments.dropFirst(2)))
            case ("sub", "list"): return try listSubscriptions(workspace)
            case ("sub", "update"): return try updateSubscriptions(workspace, try ParsedArguments(arguments.dropFirst(2)))
            case ("sub", "nodes"): return try listNodes(workspace, try ParsedArguments(arguments.dropFirst(2)))
            case ("device", "list"): return listDevices()
            case ("ext", "list"): return try listExtensions(workspace)
            case ("ext", "add"): return try addExtension(workspace, try ParsedArguments(arguments.dropFirst(2)))
            case ("ext", "remove"): return try removeExtension(workspace, try ParsedArguments(arguments.dropFirst(2)))
            case ("launch", _): return try launch(workspace, try ParsedArguments(arguments.dropFirst()), probe: false)
            case ("probe", _): return try launch(workspace, try ParsedArguments(arguments.dropFirst()), probe: true)
            case ("help", _), ("--help", _), ("-h", _), (nil, _):
                print(usage)
                return 0
            default:
                printError("未知命令：\(arguments.joined(separator: " "))\n\(usage)")
                return 64
            }
        } catch let error as CLIError {
            printError(error.message)
            return 64
        } catch {
            printError("失败：\(error)")
            return 1
        }
    }

    // MARK: - profile

    private static func listProfiles(_ workspace: SafarierWorkspace) throws -> Int32 {
        let proxies = Dictionary(uniqueKeysWithValues: try workspace.proxies.all().map { ($0.id, $0) })
        let subscriptions = Dictionary(uniqueKeysWithValues: try workspace.subscriptions.all().map { ($0.id, $0) })
        let rows = try workspace.profiles.all().map { profile -> [String] in
            [
                profile.id.uuidString,
                profile.mode.rawValue,
                workspace.isRunning(profile.id) ? "running" : "-",
                profile.name,
                outboundLabel(profile, proxies: proxies, subscriptions: subscriptions),
                profile.followProxyLanguages ? "proxy" : profile.languages.isEmpty ? "-" : profile.languages.joined(separator: ","),
                profile.followProxyTimeZone ? "proxy" : profile.timeZoneIdentifier ?? "-",
                profile.spi.description,
                profile.deviceModel ?? "-",
            ]
        }
        printTable(["ID", "MODE", "STATE", "NAME", "PROXY", "LANG", "TZ", "SPI", "DEVICE"], rows)
        return 0
    }

    private static func outboundLabel(_ profile: Profile, proxies: [UUID: ProxySettings], subscriptions: [UUID: Subscription]) -> String {
        if let subscriptionID = profile.subscriptionID {
            let name = profile.nodeName ?? ""
            guard let subscription = subscriptions[subscriptionID] else { return "missing-sub:\(subscriptionID.uuidString.prefix(8))" }
            return subscription.nodes.contains { $0.name == name } ? "node:\(name)" : "missing-node:\(name)"
        }
        return profile.proxyID.map { proxies[$0]?.name ?? "missing:\($0.uuidString.prefix(8))" } ?? "-"
    }

    /// `--proxy`、`--sub`/`--node` 互斥；校验引用存在。返回 nil 表示命令行没提出站。
    private static func parseOutbound(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> (proxyID: UUID?, subscriptionID: UUID?, nodeName: String?)? {
        let rawProxy = args.value("--proxy")
        let rawSub = args.value("--sub")
        let rawNode = args.value("--node")
        if rawProxy != nil, rawSub != nil || rawNode != nil {
            throw CLIError("--proxy 和 --sub/--node 只能二选一")
        }
        if let rawProxy {
            if rawProxy == "none" { return (nil, nil, nil) }
            guard let proxyID = UUID(uuidString: rawProxy) else { throw CLIError("--proxy 不是合法 UUID：\(rawProxy)") }
            guard try workspace.proxies.record(id: proxyID) != nil else { throw CLIError("找不到代理 \(rawProxy)") }
            return (proxyID, nil, nil)
        }
        if rawNode == "none", rawSub == nil { return (nil, nil, nil) }
        guard rawSub != nil || rawNode != nil else { return nil }
        guard let rawSub, let rawNode else { throw CLIError("--sub 和 --node 要一起给") }
        guard let subscriptionID = UUID(uuidString: rawSub) else { throw CLIError("--sub 不是合法 UUID：\(rawSub)") }
        guard let subscription = try workspace.subscriptions.record(id: subscriptionID) else { throw CLIError("找不到订阅 \(rawSub)") }
        guard subscription.nodes.contains(where: { $0.name == rawNode }) else {
            throw CLIError("订阅「\(subscription.name)」里没有节点「\(rawNode)」（用 sub nodes \(rawSub) 查看）")
        }
        return (nil, subscriptionID, rawNode)
    }

    private static func parseDevice(_ raw: String) throws -> String? {
        if raw == "none" { return nil }
        guard MacDeviceModel.preset(raw) != nil else {
            throw CLIError("--device 只能是 none 或 \(MacDeviceModel.presets.map(\.id).joined(separator: "、"))")
        }
        return raw
    }

    private static func createProfile(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let name = try args.required("--name")
        let mode = try args.value("--mode").map { raw -> ProfileMode in
            guard let mode = ProfileMode(rawValue: raw) else { throw CLIError("--mode 只能是 persistent 或 ephemeral") }
            return mode
        } ?? .persistent
        let outbound = try parseOutbound(workspace, args)
        let deviceModel = try args.value("--device").flatMap(parseDevice)
        let startURL = try args.value("--url").map(parseURL)
        let language = args.value("--lang").map(parseLanguageOption)
        let timeZone = args.value("--tz").map(parseTimeZoneOption)

        let profile = Profile(
            name: name,
            mode: mode,
            proxyID: outbound?.proxyID,
            languages: language?.languages ?? [],
            timeZoneIdentifier: timeZone?.identifier,
            followProxyLanguages: language?.follow ?? false,
            followProxyTimeZone: timeZone?.follow ?? false,
            startURL: startURL,
            notes: args.value("--notes") ?? "",
            spi: try args.spi() ?? .defaultFeatures,
            subscriptionID: outbound?.subscriptionID,
            nodeName: outbound?.nodeName,
            deviceModel: deviceModel
        )
        try workspace.profiles.insert(profile)
        print(profile.id.uuidString)
        return 0
    }

    /// 只改给出的字段；`none` 清空可选字段。模式（persistent/ephemeral）不能改，数据目录跟着 id 走。
    private static func updateProfile(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let id = try args.positionalUUID(0, name: "PROFILE_ID")
        guard var profile = try workspace.profiles.record(id: id) else { throw CLIError("找不到 profile \(id.uuidString)") }
        if let name = args.value("--name") { profile.name = name }
        if let option = args.value("--lang").map(parseLanguageOption) {
            profile.followProxyLanguages = option.follow
            profile.languages = option.languages
        }
        if let option = args.value("--tz").map(parseTimeZoneOption) {
            profile.followProxyTimeZone = option.follow
            profile.timeZoneIdentifier = option.identifier
        }
        if let raw = args.value("--url") { profile.startURL = raw == "none" ? nil : try parseURL(raw) }
        if let raw = args.value("--notes") { profile.notes = raw }
        if args.value("--node") == "none", args.value("--sub") == nil, args.value("--proxy") == nil {
            // 只解绑订阅节点；独立代理（如果有）不动。
            profile.subscriptionID = nil
            profile.nodeName = nil
        } else if let outbound = try parseOutbound(workspace, args) {
            profile.proxyID = outbound.proxyID
            profile.subscriptionID = outbound.subscriptionID
            profile.nodeName = outbound.nodeName
        }
        if let raw = args.value("--device") { profile.deviceModel = try parseDevice(raw) }
        if let spi = try args.spi() { profile.spi = spi }
        try workspace.profiles.update(profile)
        if workspace.isRunning(id) {
            print("已更新 \(profile.name)；它正在运行，重启后生效")
        } else {
            print("已更新 \(profile.name)")
        }
        return 0
    }

    private static func parseURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), url.scheme != nil else { throw CLIError("--url 不是合法 URL：\(raw)") }
        return url
    }

    private static func parseLanguages(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `--lang`：proxy / auto 跟随代理出口，system / none 跟随系统，其它是逗号分隔的语言标签。
    static func parseLanguageOption(_ raw: String) -> (follow: Bool, languages: [String]) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "proxy", "auto": return (true, [])
        case "system", "none", "": return (false, [])
        default: return (false, parseLanguages(raw))
        }
    }

    /// `--tz`：proxy / auto 跟随代理出口，system / none 跟随系统，其它是时区标识。
    static func parseTimeZoneOption(_ raw: String) -> (follow: Bool, identifier: String?) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        switch value.lowercased() {
        case "proxy", "auto": return (true, nil)
        case "system", "none", "": return (false, nil)
        default: return (false, value)
        }
    }

    /// 复制环境：设置全部照抄、换新 ID；不复制网站数据。
    private static func cloneProfile(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let id = try args.positionalUUID(0, name: "PROFILE_ID")
        guard let source = try workspace.profiles.record(id: id) else { throw CLIError("找不到 profile \(id.uuidString)") }
        let existing = Set(try workspace.profiles.all().map(\.name))
        let name = args.value("--name") ?? Profile.duplicateName(for: source.name, existing: existing)
        let copy = source.duplicated(name: name)
        try workspace.profiles.insert(copy)
        print(copy.id.uuidString)
        print("已复制「\(source.name)」为「\(copy.name)」（\(copy.mode.rawValue)，SPI \(copy.spi.description)，不含网站数据）")
        return 0
    }

    private static func deleteProfile(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let id = try args.positionalUUID(0, name: "PROFILE_ID")
        guard !workspace.isRunning(id) else { throw CLIError("profile \(id.uuidString) 正在运行，先关掉它的窗口") }
        guard let profile = try workspace.profiles.record(id: id) else { throw CLIError("找不到 profile \(id.uuidString)") }
        // 先清数据再删记录：清除失败时记录还在，可以重试，不会留下没人认领的数据目录。
        let purge = args.flag("--purge-data") && profile.mode == .persistent
        if purge {
            try waitForMainActorTask {
                try await DataStoreManager().removePersistentData(for: id)
            }
        }
        try workspace.profiles.delete(id: id)
        workspace.removeRunnerArtifacts(for: id)
        print(purge ? "已删除 \(profile.name)，并清除了它的网站数据" : "已删除 \(profile.name)")
        return 0
    }

    // MARK: - proxy

    private static func listProxies(_ workspace: SafarierWorkspace) throws -> Int32 {
        let rows = try workspace.proxies.all().map { proxy in
            [proxy.id.uuidString, proxy.kind.rawValue, "\(proxy.host):\(proxy.port)", proxy.username ?? "-", proxy.name]
        }
        printTable(["ID", "KIND", "ENDPOINT", "USER", "NAME"], rows)
        return 0
    }

    private static func addProxy(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        guard let kind = ProxyKind(rawValue: try args.required("--kind")) else {
            throw CLIError("--kind 只能是 socks5 或 httpConnect")
        }
        guard let port = Int(try args.required("--port")) else { throw CLIError("--port 必须是整数") }
        let username = args.value("--username")
        let wantsPassword = args.flag("--password-stdin")
        if wantsPassword, username == nil { throw CLIError("--password-stdin 需要同时给 --username") }
        if username != nil, !wantsPassword { throw CLIError("给了 --username 就要用 --password-stdin 提供密码") }

        let proxy = ProxySettings(
            name: try args.required("--name"),
            kind: kind,
            host: try args.required("--host"),
            port: port,
            username: username
        )
        try proxy.validate()
        if wantsPassword {
            guard let password = readLine(strippingNewline: true), !password.isEmpty else {
                throw CLIError("没有从标准输入读到密码")
            }
            try KeychainCredentialStore().setPassword(password, forKey: proxy.credentialKey)
        }
        do {
            try workspace.proxies.insert(proxy)
        } catch {
            try? KeychainCredentialStore().removePassword(forKey: proxy.credentialKey)
            throw error
        }
        print(proxy.id.uuidString)
        return 0
    }

    private static func deleteProxy(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let id = try args.positionalUUID(0, name: "PROXY_ID")
        let users = try workspace.profiles.all().filter { $0.proxyID == id }
        guard users.isEmpty else {
            throw CLIError("还有 profile 在用这个代理：\(users.map(\.name).joined(separator: ", "))")
        }
        let removed = try workspace.proxies.delete(id: id)
        try KeychainCredentialStore().removePassword(forKey: removed.credentialKey)
        print("已删除代理 \(removed.name)")
        return 0
    }

    // MARK: - subscriptions

    private static func listSubscriptions(_ workspace: SafarierWorkspace) throws -> Int32 {
        let rows = try workspace.subscriptions.all().map { subscription in
            [
                subscription.id.uuidString,
                subscription.name,
                subscription.url.absoluteString,
                "\(subscription.nodes.count)",
                subscription.updatedAt.map(Self.displayDate) ?? "-",
            ]
        }
        printTable(["ID", "NAME", "URL", "NODES", "UPDATED"], rows)
        return 0
    }

    /// 订阅网址先拉取成功再保存；直接给的节点链接先解析成功，原文存成本机文件，订阅地址指向它（和图形界面一致）。
    private static func addSubscription(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let name = try args.required("--name")
        var input = try args.required("--url")
        if input == "-" {
            input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        let id = UUID()
        let url: URL
        var result = SubscriptionParseResult(nodes: [])
        do {
            if let remote = InlineSubscription.subscriptionURL(from: input) {
                url = remote
                try waitForMainActorTask {
                    result = try await SubscriptionFetcher().fetchResult(from: remote)
                }
            } else {
                let stored = try InlineSubscription.store(input, id: id, in: workspace.root)
                url = stored.url
                result = stored.result
            }
        } catch {
            // 解析错误里可能带着整行链接（含密码）：只显示概要。
            throw CLIError("添加订阅失败：\(DisplayText.describe(error))")
        }
        let subscription = Subscription(id: id, name: name, url: url, updatedAt: Date(), nodes: result.nodes)
        do {
            try workspace.subscriptions.insert(subscription)
        } catch {
            InlineSubscription.remove(url, in: workspace.root)
            throw error
        }
        print("\(subscription.id.uuidString) (\(result.nodes.count) nodes)")
        if result.skippedCount > 0 { print(DisplayText.importSummary(result)) }
        return 0
    }

    private static func updateSubscriptions(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let subscriptions: [Subscription]
        if args.positionals.isEmpty {
            subscriptions = try workspace.subscriptions.all()
        } else {
            let id = try args.positionalUUID(0, name: "SUBSCRIPTION_ID")
            guard let subscription = try workspace.subscriptions.record(id: id) else {
                throw CLIError("找不到 subscription \(id.uuidString)")
            }
            subscriptions = [subscription]
        }
        var updated = 0
        for var subscription in subscriptions {
            var result = SubscriptionParseResult(nodes: [])
            try waitForMainActorTask {
                result = try await SubscriptionFetcher().fetchResult(from: subscription.url)
            }
            // 订阅这次返回的内容里没有节点（服务器偶尔返回空内容）：不拿空列表覆盖已有节点。
            if result.nodes.isEmpty, !subscription.nodes.isEmpty {
                printError("\(subscription.name)：这次没有拿到节点，保留原来的 \(subscription.nodes.count) 个节点")
                continue
            }
            subscription.nodes = result.nodes
            subscription.updatedAt = Date()
            try workspace.subscriptions.update(subscription)
            updated += 1
            print("已更新 \(subscription.name)：\(result.nodes.count) nodes" + (result.skippedCount > 0 ? "（\(DisplayText.importSummary(result))）" : ""))
        }
        if subscriptions.isEmpty { print("（空）") }
        return updated == 0 && !subscriptions.isEmpty ? 1 : 0
    }

    private static func listNodes(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let id = try args.positionalUUID(0, name: "SUBSCRIPTION_ID")
        guard let subscription = try workspace.subscriptions.record(id: id) else { throw CLIError("找不到 subscription \(id.uuidString)") }
        let rows = subscription.nodes.enumerated().map { index, node in
            ["\(index + 1)", node.type.rawValue, "\(node.server):\(node.serverPort)", node.name]
        }
        printTable(["#", "TYPE", "SERVER", "NAME"], rows)
        return 0
    }

    private static func listDevices() -> Int32 {
        let rows = MacDeviceModel.presets.map { model in
            [model.id, "\(model.cpuCores)", "\(model.chip) \(model.gpuCores)C", "\(model.viewportWidth)x\(model.viewportHeight)@\(model.scale)x", model.name]
        }
        printTable(["ID", "CPU", "GPU", "VIEWPORT", "NAME"], rows)
        return 0
    }

    private static func displayDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - launch / probe

    private static func listExtensions(_ workspace: SafarierWorkspace) throws -> Int32 {
        let records = try workspace.extensionRecords()
        guard !records.isEmpty else { print("（空）"); return 0 }
        printTable(["ID", "NAME", "VERSION", "MANIFEST", "PROFILES"], records.map {
            [$0.id.uuidString, $0.name, $0.version, String($0.manifestVersion), String($0.enabledProfileIDs.count)]
        })
        return 0
    }

    private static func addExtension(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let path = try args.positional(0, name: "PATH")
        let record = try workspace.importExtension(from: URL(fileURLWithPath: path))
        if let rawProfile = args.value("--profile") {
            guard let profileID = UUID(uuidString: rawProfile) else { throw CLIError("--profile 不是合法 UUID：\(rawProfile)") }
            guard try workspace.profiles.record(id: profileID) != nil else { throw CLIError("找不到 profile \(rawProfile)") }
            try workspace.enableExtension(record.id, for: profileID)
        }
        print("已安装扩展 \(record.name) \(record.version)（\(record.id.uuidString)）")
        return 0
    }

    private static func removeExtension(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let name = try args.positional(0, name: "NAME")
        let record = try workspace.removeExtension(name: name)
        print("已删除扩展 \(record.name)")
        return 0
    }

    private static func launch(_ workspace: SafarierWorkspace, _ args: ParsedArguments, probe: Bool) throws -> Int32 {
        let id = try args.positionalUUID(0, name: "PROFILE_ID")
        guard let profile = try workspace.profiles.record(id: id) else { throw CLIError("找不到 profile \(id.uuidString)") }
        guard !workspace.isRunning(id) else { throw CLIError("profile \(profile.name) 已经在运行") }
        let url = try args.value("--url").map(parseURL)
        let spiOverride = try args.spi()

        if probe {
            return try runProbe(workspace.runnerSpec(for: profile, url: url, probe: true, spiOverride: spiOverride))
        }
        let pid = try workspace.launch(profile, url: url, spiOverride: spiOverride)
        print("已启动 \(profile.name)，pid \(pid)，日志 \(workspace.runnerLogURL(for: profile.id).path)")
        return 0
    }

    /// 探针要等结果，所以直接起子进程并转发它的 stdout/stderr。
    private static func runProbe(_ spec: RunnerLaunchSpec) throws -> Int32 {
        let process = Process()
        process.executableURL = RunnerLauncher.currentExecutableURL()
        process.arguments = spec.arguments()
        process.environment = spec.environment(inheriting: ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - helpers

    /// CLI 不跑 NSApplication，所以手动转主 RunLoop，等 @MainActor 异步任务结束。
    private static func waitForMainActorTask(_ body: @escaping @MainActor () async throws -> Void) throws {
        final class Box: @unchecked Sendable { var result: Result<Void, Error>? }
        let box = Box()
        Task { @MainActor in
            do {
                try await body()
                box.result = .success(())
            } catch {
                box.result = .failure(error)
            }
        }
        while box.result == nil {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        try box.result?.get()
    }

    private static func printTable(_ header: [String], _ rows: [[String]]) {
        guard !rows.isEmpty else {
            print("（空）")
            return
        }
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        for row in all {
            print(row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces))
        }
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

struct CLIError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// `--key value` 选项、无值开关（flags）和位置参数。
struct ParsedArguments {
    private(set) var positionals: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    init<S: Sequence>(_ arguments: S, flags knownFlags: Set<String> = []) throws where S.Element == String {
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            if knownFlags.contains(arg) {
                flags.insert(arg)
            } else if arg.hasPrefix("--") {
                guard let value = iterator.next() else { throw CLIError("\(arg) 缺少参数值") }
                options[arg] = value
            } else {
                positionals.append(arg)
            }
        }
    }

    func value(_ key: String) -> String? { options[key] }
    func flag(_ key: String) -> Bool { flags.contains(key) }

    func required(_ key: String) throws -> String {
        guard let value = options[key], !value.isEmpty else { throw CLIError("缺少 \(key)") }
        return value
    }

    /// `--spi` 没给时返回 nil。
    func spi() throws -> SPIFeatures? {
        guard let raw = options["--spi"] else { return nil }
        do {
            return try SPIFeatures(parsing: raw)
        } catch {
            throw CLIError("--spi 只能是 default、none、all，或 afp、tz、webrtc、safari、webgpu、fontlist 的逗号组合：\(raw)")
        }
    }

    func positionalUUID(_ index: Int, name: String) throws -> UUID {
        guard positionals.indices.contains(index) else { throw CLIError("缺少 \(name)") }
        guard let id = UUID(uuidString: positionals[index]) else { throw CLIError("\(name) 不是合法 UUID：\(positionals[index])") }
        return id
    }

    func positional(_ index: Int, name: String) throws -> String {
        guard positionals.indices.contains(index), !positionals[index].isEmpty else { throw CLIError("缺少 \(name)") }
        return positionals[index]
    }
}
