import Foundation
import Darwin
import SafarierCore

public enum SingboxProcessError: Error, Equatable {
    case alreadyRunning(UUID)
    case notRunning(UUID)
    case executableNotFound(URL)
    /// 自带的 sing-box 带着下载来的隔离标记，而且去不掉（见 `clearQuarantine`）。
    case quarantined(URL)
    case noFreePort
    /// sing-box 在本地端口就绪前就退出了（多半是配置或节点参数有问题，原因在它的日志里）。
    case exitedEarly(status: Int32)
    case startTimeout(port: Int)
    case processIdentityUnavailable(Int32)
}

extension SingboxProcessError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .alreadyRunning: return "这个环境的 sing-box 已经在运行。"
        case .notRunning: return "这个环境的 sing-box 没有在运行。"
        case .executableNotFound(let url):
            return "找不到 sing-box（\(url.path)），订阅节点要靠它连出去。Safarier.app 里自带一份；"
                + "单独用命令行版时请 brew install sing-box，或用环境变量 SAFARIER_SINGBOX 指定路径。"
        case .quarantined(let url):
            return "macOS 拦下了自带的 sing-box：\(url.path) 带着下载来的隔离标记，而且所在位置是只读的"
                + "（多半是 App 还在「下载」里，被系统放到了临时位置运行）。把 Safarier.app 拖进「应用程序」，"
                + "或在终端运行 xattr -dr com.apple.quarantine /Applications/Safarier.app，再重新打开。"
        case .noFreePort: return "127.0.0.1 上没有空闲端口给 sing-box。"
        case .exitedEarly(let status): return "sing-box 启动后马上退出了（退出码 \(status)），多半是节点参数有问题，详情见日志。"
        case .startTimeout(let port): return "sing-box 没有在规定时间内监听 127.0.0.1:\(port)。"
        case .processIdentityUnavailable(let pid): return "无法核验 sing-box 进程 \(pid) 的身份，已停止启动。"
        }
    }
}

/// 每个 profile 一个 sing-box 子进程：节点出站 → `127.0.0.1:<port>` 的 SOCKS5 入站，交给 WebKit。
///
/// 状态目录里每个 profile 两个文件：`<id>.json`（配置，含节点凭据，权限 0600）和 `<id>.pid`（JSON 进程身份）。
/// 正常停止时两个都删掉；Runner 被 SIGKILL 或崩溃时会留下来，下次启动同一 profile、
/// 或图形管理器发现该 profile 没在运行时，用 `reapOrphan` 按 pid 文件清理。
public final class SingboxProcessManager: @unchecked Sendable {
    public let executableURL: URL
    public let stateDirectory: URL
    public let portRange: ClosedRange<Int>
    public let logLevel: String
    /// sing-box 的 stdout/stderr 写到这里；nil 时丢弃。
    public let logHandle: FileHandle?

    private var processes: [UUID: Process] = [:]
    private var ports: [UUID: Int] = [:]
    private let lock = NSLock()

    public init(
        executableURL: URL = SingboxProcessManager.defaultExecutableURL,
        stateDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Safarier/sing-box", isDirectory: true),
        portRange: ClosedRange<Int> = 20_001...39_999,
        logLevel: String = "warn",
        logHandle: FileHandle? = nil
    ) {
        self.executableURL = executableURL
        self.stateDirectory = stateDirectory
        self.portRange = portRange
        self.logLevel = logLevel
        self.logHandle = logHandle
    }

    /// 找到的 sing-box；一个都没有时是 Homebrew 的默认位置（启动时报 executableNotFound）。
    public static var defaultExecutableURL: URL {
        locateExecutable() ?? URL(fileURLWithPath: "/opt/homebrew/bin/sing-box")
    }

    /// 依次是 `SAFARIER_SINGBOX` 指定的路径、App 自带的 `Contents/Helpers/sing-box`、Homebrew 的两个位置、PATH。
    /// 从访达启动的 App 拿不到 shell 的 PATH，所以先查固定位置。
    public static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledExecutable: URL? = SingboxProcessManager.bundledExecutableURL()
    ) -> URL? {
        if let override = environment["SAFARIER_SINGBOX"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let path = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/sing-box" }
        return ([bundledExecutable?.path].compactMap { $0 } + ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"] + path)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// `Safarier.app/Contents/MacOS/Safarier` 旁边的 `Contents/Helpers/sing-box`（scripts/build-app.sh 放进去的）。
    /// 不是从 .app 里运行（swift run、测试）时为 nil。
    public static func bundledExecutableURL(mainExecutable: URL = RunnerLauncher.currentExecutableURL()) -> URL? {
        let macOS = mainExecutable.resolvingSymlinksInPath().deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents" else { return nil }
        return contents.appendingPathComponent("Helpers/sing-box")
    }

    // MARK: - 隔离标记

    static let quarantineAttribute = "com.apple.quarantine"

    /// 从浏览器下载的压缩包解出来的文件都带隔离标记。用户在「仍要打开」里放行的是 Safarier.app，
    /// 里面的 sing-box 不跟着放行，直接拉起会卡在 Gatekeeper 的确认框上，最后被拒绝。
    /// 它在 App 签名的封装里，所以只对自带的这一份去掉标记；别处的 sing-box 不动。
    static func clearQuarantine(of executable: URL, bundled: URL? = bundledExecutableURL()) throws {
        guard let bundled,
              executable.resolvingSymlinksInPath().path == bundled.resolvingSymlinksInPath().path,
              isQuarantined(executable) else { return }
        removexattr(executable.path, quarantineAttribute, 0)
        if isQuarantined(executable) { throw SingboxProcessError.quarantined(executable) }
    }

    /// 有隔离标记，而且用户没放行过（标志字段带 0x40 表示已放行）。
    static func isQuarantined(_ url: URL) -> Bool {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = getxattr(url.path, quarantineAttribute, &buffer, buffer.count - 1, 0, 0)
        guard length > 0 else { return false }
        let flags = String(cString: buffer).split(separator: ";").first.flatMap { UInt32($0, radix: 16) } ?? 0
        return flags & 0x40 == 0
    }

    // MARK: - 端口

    /// 按 profile id 选一个固定的起点，跳过已经被占用的端口（实际试绑 127.0.0.1）。
    public func port(for profileID: UUID) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        if let port = ports[profileID] { return port }
        let available = portRange.count
        let hex = profileID.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let seed = Int(hex, radix: 16) ?? 0
        let used = Set(ports.values)
        for offset in 0..<available {
            let candidate = portRange.lowerBound + ((seed + offset) % available)
            if !used.contains(candidate), Self.isPortAvailable(candidate) {
                ports[profileID] = candidate
                return candidate
            }
        }
        throw SingboxProcessError.noFreePort
    }

    public static func isPortAvailable(_ port: Int, host: String = SingboxConfigBuilder.defaultInboundAddress) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = Self.socketAddress(host: host, port: port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    private static func isAcceptingConnections(_ port: Int, host: String = SingboxConfigBuilder.defaultInboundAddress) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = Self.socketAddress(host: host, port: port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    private static func socketAddress(host: String, port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &address.sin_addr)
        return address
    }

    // MARK: - 文件

    public func configurationFileURL(for profileID: UUID) -> URL {
        Self.configurationFileURL(for: profileID, in: stateDirectory)
    }

    public func pidFileURL(for profileID: UUID) -> URL {
        Self.pidFileURL(for: profileID, in: stateDirectory)
    }

    static func configurationFileURL(for profileID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(profileID.uuidString).json")
    }

    static func pidFileURL(for profileID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(profileID.uuidString).pid")
    }

    public func configuration(for profileID: UUID, node: SubscriptionNode) throws -> SingboxConfiguration {
        try SingboxConfigBuilder.makeConfiguration(inboundPort: port(for: profileID), node: node, logLevel: logLevel)
    }

    // MARK: - 生命周期

    /// 写配置、起 sing-box，立即返回 pid；要等本地端口可用请接着调 `waitUntilReady`。
    @discardableResult
    public func start(profileID: UUID, node: SubscriptionNode) throws -> Int32 {
        lock.lock()
        if let process = processes[profileID], process.isRunning {
            lock.unlock()
            throw SingboxProcessError.alreadyRunning(profileID)
        }
        lock.unlock()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SingboxProcessError.executableNotFound(executableURL)
        }
        try Self.clearQuarantine(of: executableURL)
        // 同一个 profile 上次没清理掉的 sing-box（Runner 崩溃、被 SIGKILL）先结束，让出端口。
        Self.reapOrphan(profileID: profileID, in: stateDirectory)

        let config = try configuration(for: profileID, node: node)
        let configURL = configurationFileURL(for: profileID)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try Self.writePrivate(config.encoded(), to: configURL)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["run", "-c", configURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice
        do {
            try process.run()
            if let identity = Self.processIdentity(of: process.processIdentifier) {
                let record = ProcessRecord(pid: process.processIdentifier, identity: identity, configurationPath: configURL.standardizedFileURL.path)
                try Self.writePrivate(JSONEncoder().encode(record), to: pidFileURL(for: profileID))
            } else if process.isRunning {
                throw SingboxProcessError.processIdentityUnavailable(process.processIdentifier)
            }
        } catch {
            if process.isRunning {
                Self.terminate(pid: process.processIdentifier, isRunning: { process.isRunning })
            }
            removeStateFiles(for: profileID)
            throw error
        }
        lock.lock()
        processes[profileID] = process
        lock.unlock()
        return process.processIdentifier
    }

    /// 等到本地 SOCKS5 端口能连上，返回端口。sing-box 先退出就抛 `exitedEarly`。
    @discardableResult
    public func waitUntilReady(profileID: UUID, timeout: TimeInterval = 10) throws -> Int {
        lock.lock()
        let process = processes[profileID]
        let port = ports[profileID]
        lock.unlock()
        guard let process, let port else { throw SingboxProcessError.notRunning(profileID) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard process.isRunning else {
                process.waitUntilExit()
                throw SingboxProcessError.exitedEarly(status: process.terminationStatus)
            }
            if Self.isAcceptingConnections(port) { return port }
            usleep(50_000)
        }
        throw SingboxProcessError.startTimeout(port: port)
    }

    /// SIGTERM，最多等 2 秒再 SIGKILL；删掉配置和 pid 文件。
    public func stop(profileID: UUID) throws {
        lock.lock()
        let process = processes.removeValue(forKey: profileID)
        ports.removeValue(forKey: profileID)
        lock.unlock()
        defer { removeStateFiles(for: profileID) }
        guard let process else { throw SingboxProcessError.notRunning(profileID) }
        Self.terminate(pid: process.processIdentifier, isRunning: { process.isRunning })
    }

    public func stopAll() {
        lock.lock()
        let ids = Array(processes.keys)
        lock.unlock()
        for id in ids { try? stop(profileID: id) }
    }

    public func isRunning(profileID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return processes[profileID]?.isRunning == true
    }

    public func processIdentifier(for profileID: UUID) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        guard let process = processes[profileID], process.isRunning else { return nil }
        return process.processIdentifier
    }

    /// 按 pid 文件结束遗留的 sing-box。只有该 profile 没有 Runner 在跑时才能调用（Runner 拿着 profile 锁时调用是安全的，
    /// 因为那时遗留进程一定不是它自己的）。每次发信号前核验启动时间和路径，拒绝旧版纯 PID 或身份不匹配的记录。
    @discardableResult
    public static func reapOrphan(profileID: UUID, in directory: URL) -> Bool {
        let pidURL = pidFileURL(for: profileID, in: directory)
        guard let data = try? Data(contentsOf: pidURL) else { return false }
        defer {
            try? FileManager.default.removeItem(at: pidURL)
            try? FileManager.default.removeItem(at: configurationFileURL(for: profileID, in: directory))
        }
        guard let record = try? JSONDecoder().decode(ProcessRecord.self, from: data), record.pid > 0,
              record.configurationPath == configurationFileURL(for: profileID, in: directory).standardizedFileURL.path,
              processIdentity(of: record.pid) == record.identity else { return false }
        terminate(pid: record.pid, isRunning: { processIdentity(of: record.pid) == record.identity })
        return true
    }

    /// 图形管理器定时调用：有遗留 pid 文件、且拿得到 profile 锁（没有 Runner 在跑）时才清理。
    /// 拿锁这一步排除了"Runner 刚起来、新 sing-box 刚写 pid 文件"的竞争。
    @discardableResult
    public static func reapOrphanIfIdle(profileID: UUID, workspace: SafarierWorkspace) -> Bool {
        let directory = workspace.singboxDirectory
        guard FileManager.default.fileExists(atPath: pidFileURL(for: profileID, in: directory).path),
              let lock = try? ProfileLock.acquire(profileID: profileID, in: workspace.locksDirectory) else { return false }
        defer { lock.release() }
        return reapOrphan(profileID: profileID, in: directory)
    }

    private static func terminate(pid: Int32, isRunning: () -> Bool) {
        guard isRunning() else { return }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while isRunning(), Date() < deadline { usleep(20_000) }
        if isRunning() { kill(pid, SIGKILL) }
    }

    struct ProcessIdentity: Codable, Equatable {
        var executablePath: String
        var startSeconds: UInt64
        var startMicroseconds: UInt64
    }

    struct ProcessRecord: Codable {
        var pid: Int32
        var identity: ProcessIdentity
        var configurationPath: String
    }

    /// 同名程序也可能是 PID 复用后的另一进程；使用内核启动时间区分。
    static func processIdentity(of pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_status != SZOMB else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return ProcessIdentity(executablePath: String(cString: buffer), startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    private func removeStateFiles(for profileID: UUID) {
        try? FileManager.default.removeItem(at: configurationFileURL(for: profileID))
        try? FileManager.default.removeItem(at: pidFileURL(for: profileID))
    }

    /// 配置里有节点密码，只给自己读写。
    private static func writePrivate(_ data: Data, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    deinit {
        stopAll()
    }
}
