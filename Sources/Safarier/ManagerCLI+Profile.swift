import Foundation
import SafarierCore
import SafarierWebKit

extension ManagerCLI {
    // MARK: - profile

    static func listProfiles(_ workspace: SafarierWorkspace) throws -> Int32 {
        let proxies = Dictionary(uniqueKeysWithValues: try workspace.proxies.all().map { ($0.id, $0) })
        let subscriptions = Dictionary(uniqueKeysWithValues: try workspace.subscriptions.all().map { ($0.id, $0) })
        let rows = try workspace.profiles.all().map { profile -> [String] in
            let languages = profile.resolvedLanguages()
            return [
                profile.id.uuidString,
                profile.mode.rawValue,
                workspace.isRunning(profile.id) ? "running" : "-",
                profile.name,
                outboundLabel(profile, proxies: proxies, subscriptions: subscriptions),
                languages.isEmpty ? (profile.followProxyLanguages ? "proxy" : "timezone") : languages.joined(separator: ","),
                profile.followProxyTimeZone ? "proxy" : profile.timeZoneIdentifier ?? "-",
                profile.spi.description,
                profile.deviceModel ?? "-",
            ]
        }
        printTable(["ID", "MODE", "STATE", "NAME", "PROXY", "LANG", "TZ", "SPI", "DEVICE"], rows)
        return 0
    }

    static func outboundLabel(_ profile: Profile, proxies: [UUID: ProxySettings], subscriptions: [UUID: Subscription]) -> String {
        switch profile.outbound {
        case .customSingbox:
            return "custom:sing-box"
        case .subscriptionNode(let subscriptionID, let name):
            guard let subscription = subscriptions[subscriptionID] else { return "missing-sub:\(subscriptionID.uuidString.prefix(8))" }
            return subscription.nodes.contains { $0.name == name } ? "node:\(name)" : "missing-node:\(name)"
        case .proxy(let id):
            return proxies[id]?.name ?? "missing:\(id.uuidString.prefix(8))"
        case .direct(let bypass):
            return bypass ? "direct(local)" : "-"
        }
    }

    /// `--proxy`、`--sub`/`--node` 互斥；校验引用存在。返回 nil 表示命令行没提出站。
    private static func parseOutbound(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Profile.Outbound? {
        let rawProxy = args.value("--proxy")
        let rawSub = args.value("--sub")
        let rawNode = args.value("--node")
        if rawProxy != nil, rawSub != nil || rawNode != nil {
            throw CLIError(L10n.text("--proxy 和 --sub/--node 只能二选一"))
        }
        if let rawProxy {
            if rawProxy == "none" { return .direct(bypassSystemProxy: false) }
            guard let proxyID = UUID(uuidString: rawProxy) else {
                throw CLIError(L10n.text("--proxy 不是合法 UUID：%@", rawProxy))
            }
            guard try workspace.proxies.record(id: proxyID) != nil else {
                throw CLIError(L10n.text("找不到代理 %@", rawProxy))
            }
            return .proxy(proxyID)
        }
        if rawNode == "none", rawSub == nil { return .direct(bypassSystemProxy: false) }
        guard rawSub != nil || rawNode != nil else { return nil }
        guard let rawSub, let rawNode else { throw CLIError(L10n.text("--sub 和 --node 要一起给")) }
        guard let subscriptionID = UUID(uuidString: rawSub) else {
            throw CLIError(L10n.text("--sub 不是合法 UUID：%@", rawSub))
        }
        guard let subscription = try workspace.subscriptions.record(id: subscriptionID) else {
            throw CLIError(L10n.text("找不到订阅 %@", rawSub))
        }
        guard subscription.nodes.contains(where: { $0.name == rawNode }) else {
            throw CLIError(L10n.text("订阅「%@」里没有节点「%@」（用 sub nodes %@ 查看）", subscription.name, rawNode, rawSub))
        }
        return .subscriptionNode(subscriptionID: subscriptionID, nodeName: rawNode)
    }

    private static func parseDevice(_ raw: String) throws -> String? {
        if raw == "none" { return nil }
        guard MacDeviceModel.preset(raw) != nil else {
            throw CLIError(L10n.text("--device 只能是 none 或 %@", MacDeviceModel.presets.map(\.id).joined(separator: ", ")))
        }
        return raw
    }

    static func createProfile(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let name = try args.required("--name")
        let mode = try args.value("--mode").map { raw -> ProfileMode in
            guard let mode = ProfileMode(rawValue: raw) else {
                throw CLIError(L10n.text("--mode 只能是 persistent 或 ephemeral"))
            }
            return mode
        } ?? .persistent

        let parsedOutbound = try parseOutbound(workspace, args)
        let bypassSystemProxy = args.flag("--bypass-system-proxy")
        let targetOutbound: Profile.Outbound
        switch parsedOutbound {
        case .proxy, .subscriptionNode, .customSingbox:
            if bypassSystemProxy {
                throw CLIError(L10n.text("--bypass-system-proxy 不能和 --proxy 或 --sub/--node 同时使用"))
            }
            if let parsedOutbound {
                targetOutbound = parsedOutbound
            } else {
                targetOutbound = .direct(bypassSystemProxy: bypassSystemProxy)
            }
        case .direct, nil:
            targetOutbound = .direct(bypassSystemProxy: bypassSystemProxy)
        }

        let deviceModel = try args.value("--device").flatMap(parseDevice)
        let startupTabs = try startupTabsOption(args)
        let language = args.value("--lang").map(parseLanguageOption)
        let timeZone = args.value("--tz").map(parseTimeZoneOption)

        var profile = Profile(
            name: name,
            mode: mode,
            languages: language?.languages ?? [],
            timeZoneIdentifier: timeZone?.identifier,
            followProxyLanguages: language?.follow ?? false,
            followProxyTimeZone: timeZone?.follow ?? false,
            notes: args.value("--notes") ?? "",
            spi: try args.spi() ?? .defaultFeatures,
            deviceModel: deviceModel,
            startupTabs: startupTabs
        )
        profile.setOutbound(targetOutbound)
        if args.value("--spi") == nil {
            profile.spi = SPIFeatures.defaultFeatures(hasProxy: profile.hasOutboundProxy)
        }
        try validateFollowProxy(for: profile)
        try workspace.profiles.insert(profile)
        print(profile.id.uuidString)
        return 0
    }

    /// 只改给出的字段；`none` 清空可选字段。模式（persistent/ephemeral）不能改，数据目录跟着 id 走。
    static func updateProfile(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let id = try args.positionalUUID(0, name: "PROFILE_ID")
        guard var profile = try workspace.profiles.record(id: id) else { throw CLIError(L10n.text("找不到 profile %@", id.uuidString)) }
        let enableBypass = args.flag("--bypass-system-proxy")
        let disableBypass = args.flag("--no-bypass-system-proxy")
        if enableBypass && disableBypass {
            throw CLIError(L10n.text("--bypass-system-proxy 和 --no-bypass-system-proxy 不能同时使用"))
        }

        if let name = args.value("--name") { profile.name = name }
        if let option = args.value("--lang").map(parseLanguageOption) {
            profile.followProxyLanguages = option.follow
            profile.languages = option.languages
        }
        if let option = args.value("--tz").map(parseTimeZoneOption) {
            profile.followProxyTimeZone = option.follow
            profile.timeZoneIdentifier = option.identifier
        }
        if let tabs = try startupTabsOption(args) { profile.startupTabs = tabs }
        if let raw = args.value("--notes") { profile.notes = raw }

        let hadProxy = profile.hasOutboundProxy
        if args.value("--node") == "none", args.value("--sub") == nil, args.value("--proxy") == nil {
            // 只解绑订阅节点；独立代理（如果有）不动。
            profile.subscriptionID = nil
            profile.nodeName = nil
        } else if let parsedOutbound = try parseOutbound(workspace, args) {
            switch parsedOutbound {
            case .proxy, .subscriptionNode, .customSingbox:
                if enableBypass {
                    throw CLIError(L10n.text("--bypass-system-proxy 不能和 --proxy 或 --sub/--node 同时使用"))
                }
                profile.setOutbound(parsedOutbound)
            case .direct:
                profile.setOutbound(.direct(bypassSystemProxy: false))
            }
            if !hadProxy, profile.hasOutboundProxy {
                profile.spi.insert(.disableWebRTC)
            }
        }

        if enableBypass {
            // 若此时仍绑定着独立代理、订阅节点或自定义出站（例如只传了 --node none 但原本有 proxyID），必须拦截，绝不静默覆盖。
            guard !profile.hasOutboundProxy else {
                throw CLIError(L10n.text("--bypass-system-proxy 不能和已绑定的代理或节点同时使用，请先传入 --proxy none 或 --node none"))
            }
            profile.setOutbound(.direct(bypassSystemProxy: true))
        } else if disableBypass, case .direct(true) = profile.outbound {
            profile.setOutbound(.direct(bypassSystemProxy: false))
        }

        try validateFollowProxy(for: profile)
        if let raw = args.value("--device") { profile.deviceModel = try parseDevice(raw) }
        if let spi = try args.spi() { profile.spi = spi }
        try workspace.profiles.update(profile)
        if workspace.isRunning(id) {
            print(L10n.text("已更新 %@；它正在运行，重启后生效", profile.name))
        } else {
            print(L10n.text("已更新 %@", profile.name))
        }
        return 0
    }

    private static func validateFollowProxy(for profile: Profile) throws {
        if !profile.hasOutboundProxy, profile.followProxyLanguages || profile.followProxyTimeZone {
            throw CLIError(L10n.text("「跟随代理」需要选择独立代理或订阅节点。"))
        }
    }

    /// profile 的重复 --url 替换整个启动列表；不传参数则保留原设置。
    private static func startupTabsOption(_ args: ParsedArguments) throws -> [StartupTab]? {
        let urls = args.values("--url")
        guard !urls.isEmpty else { return nil }
        if urls == ["none"] { return [] }
        return try urls.map { StartupTab(url: try parseWebURL($0)) }
    }

    private static func parseWebURL(_ raw: String) throws -> URL {
        guard let url = AddressInput.webURL(for: raw) else {
            throw CLIError(L10n.text("--url 不是合法 URL：%@", raw))
        }
        return url
    }

    private static func parseLanguages(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `--lang`：proxy / auto 跟随代理，timezone（兼容 system / none）按时区匹配，其它是语言标签。
    static func parseLanguageOption(_ raw: String) -> (follow: Bool, languages: [String]) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "proxy", "auto": return (true, [])
        case "timezone", "system", "none", "": return (false, [])
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
    static func cloneProfile(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let id = try args.positionalUUID(0, name: "PROFILE_ID")
        guard let source = try workspace.profiles.record(id: id) else { throw CLIError(L10n.text("找不到 profile %@", id.uuidString)) }
        let existing = Set(try workspace.profiles.all().map(\.name))
        let name = args.value("--name") ?? Profile.duplicateName(for: source.name, existing: existing)
        let copy = source.duplicated(name: name)
        try workspace.profiles.insert(copy)
        print(copy.id.uuidString)
        print(L10n.text(
            "已复制「%@」为「%@」（%@，SPI %@，不含网站数据）",
            source.name,
            copy.name,
            copy.mode.rawValue,
            copy.spi.description
        ))
        return 0
    }

    static func deleteProfile(_ workspace: SafarierWorkspace, _ args: ParsedArguments) throws -> Int32 {
        let id = try args.positionalUUID(0, name: "PROFILE_ID")
        guard !workspace.isRunning(id) else {
            throw CLIError(L10n.text("profile %@ 正在运行，先关掉它的窗口", id.uuidString))
        }
        guard let profile = try workspace.profiles.record(id: id) else { throw CLIError(L10n.text("找不到 profile %@", id.uuidString)) }
        // 先清数据再删记录：清除失败时记录还在，可以重试，不会留下没人认领的数据目录。
        let purge = args.flag("--purge-data") && profile.mode == .persistent
        if purge {
            try waitForMainActorTask {
                try await DataStoreManager().removePersistentData(for: id)
            }
        }
        try workspace.profiles.delete(id: id)
        workspace.removeRunnerArtifacts(for: id)
        if purge {
            print(L10n.text("已删除 %@，并清除了它的网站数据", profile.name))
        } else {
            print(L10n.text("已删除 %@", profile.name))
        }
        return 0
    }
}
