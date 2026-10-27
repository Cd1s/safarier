import Foundation

/// 本地元数据目录的布局。Manager 和 Runner 用同一个根目录（默认 Application Support，可用 SAFARIER_HOME 覆盖）。
public struct SafarierWorkspace: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func `default`() throws -> SafarierWorkspace {
        SafarierWorkspace(root: try FileManager.safarierSupportDirectory())
    }

    public var profiles: ProfileRepository { .profiles(in: root) }
    public var proxies: ProxyRepository { .proxies(in: root) }
    public var subscriptions: SubscriptionRepository { .subscriptions(in: root) }
    public var locksDirectory: URL { root.appendingPathComponent("locks", isDirectory: true) }
    public var logsDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }
    /// sing-box 的配置和 pid 文件（每个 profile 一份）。配置里有节点凭据，Runner 退出时删除。
    public var singboxDirectory: URL { root.appendingPathComponent("sing-box", isDirectory: true) }

    public func isRunning(_ profileID: UUID) -> Bool {
        ProfileLock.isHeld(profileID: profileID, in: locksDirectory)
    }

    /// 正在运行的 Runner 的 pid（从锁文件读）。
    public func runnerPID(_ profileID: UUID) -> Int32? {
        ProfileLock.holderPID(profileID: profileID, in: locksDirectory)
    }

    /// Runner 的 stdout/stderr 追加到这里，和 `RunnerLauncher` 的命名一致。
    public func runnerLogURL(for profileID: UUID) -> URL {
        logsDirectory.appendingPathComponent("\(profileID.uuidString).log")
    }

    /// 删除环境之后清掉它留下的文件：Runner 日志、锁文件、sing-box 的配置（含节点凭据）和 pid。只在环境没在运行时调用。
    public func removeRunnerArtifacts(for profileID: UUID) {
        let id = profileID.uuidString
        for url in [
            runnerLogURL(for: profileID),
            locksDirectory.appendingPathComponent("\(id).lock"),
            singboxDirectory.appendingPathComponent("\(id).json"),
            singboxDirectory.appendingPathComponent("\(id).pid"),
        ] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 按 profile 生成 Runner 参数；`url` 为 nil 时用 profile 的起始网址。
    public func runnerSpec(
        for profile: Profile,
        url: URL? = nil,
        probe: Bool = false,
        spiOverride: SPIFeatures? = nil
    ) -> RunnerLaunchSpec {
        RunnerLaunchSpec(
            profileID: profile.id,
            startURL: url ?? profile.startURL,
            languages: profile.languages,
            timeZoneIdentifier: profile.timeZoneIdentifier,
            probe: probe,
            spiOverride: spiOverride
        )
    }

    /// 起一个独立的 Runner 窗口进程，返回 pid。命令行 `launch` 和图形管理器共用。
    /// `launcher` 为 nil 时用当前可执行文件，日志写到 `logsDirectory`。
    @discardableResult
    public func launch(
        _ profile: Profile,
        url: URL? = nil,
        spiOverride: SPIFeatures? = nil,
        launcher: RunnerLauncher? = nil
    ) throws -> Int32 {
        guard !isRunning(profile.id) else { throw WorkspaceError.alreadyRunning(profile.id) }
        let launcher = launcher ?? RunnerLauncher(logDirectory: logsDirectory)
        return try launcher.launch(runnerSpec(for: profile, url: url, spiOverride: spiOverride))
    }
}

public extension SafarierWorkspace {
    /// profile 绑定的订阅节点；没绑定时返回 nil，绑定了但找不到时抛错。
    func boundNode(for profile: Profile) throws -> (subscription: Subscription, node: SubscriptionNode)? {
        guard let subscriptionID = profile.subscriptionID else { return nil }
        guard let subscription = try subscriptions.record(id: subscriptionID) else {
            throw WorkspaceError.subscriptionNotFound(subscriptionID)
        }
        let name = profile.nodeName ?? ""
        guard let node = subscription.nodes.first(where: { $0.name == name }) else {
            throw WorkspaceError.nodeNotFound(subscription: subscription.name, node: name)
        }
        return (subscription, node)
    }
}

public enum WorkspaceError: Error, Equatable {
    case alreadyRunning(UUID)
    case subscriptionNotFound(UUID)
    case nodeNotFound(subscription: String, node: String)
}
