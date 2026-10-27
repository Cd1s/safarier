import Foundation

/// 抽象出进程创建，方便测试 Manager 的启动逻辑。
public protocol ProcessSpawning: Sendable {
    /// 启动后立即返回 pid，不等待子进程结束。
    func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32
}

/// 子进程退出信息。图形管理器靠它发现 Runner 启动失败，命令行不关心。
public struct ProcessExit: Equatable, Sendable {
    public var pid: Int32
    /// 正常退出时是退出码，被信号结束时是信号编号。
    public var status: Int32
    public var uncaughtSignal: Bool

    public init(pid: Int32, status: Int32, uncaughtSignal: Bool) {
        self.pid = pid
        self.status = status
        self.uncaughtSignal = uncaughtSignal
    }

    /// 退出码非 0 或崩溃算失败；被 TERM/KILL/INT/HUP 结束（用户强制退出、注销）不算。
    public var isFailure: Bool {
        uncaughtSignal ? ![SIGTERM, SIGKILL, SIGINT, SIGHUP].contains(status) : status != 0
    }
}

public struct FoundationProcessSpawner: ProcessSpawning {
    /// 在任意线程回调。
    public var onExit: (@Sendable (ProcessExit) -> Void)?

    public init(onExit: (@Sendable (ProcessExit) -> Void)? = nil) {
        self.onExit = onExit
    }

    public func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        if let logURL {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
        }
        if let onExit {
            process.terminationHandler = { process in
                onExit(ProcessExit(
                    pid: process.processIdentifier,
                    status: process.terminationStatus,
                    uncaughtSignal: process.terminationReason == .uncaughtSignal
                ))
            }
        }
        try process.run()
        return process.processIdentifier
    }
}

/// Manager 侧：把一个 profile 交给独立的 Runner 进程。每个 profile 一个进程，
/// 这样语言、时区这类进程级设置互不影响，崩溃也不会连带。
public struct RunnerLauncher: Sendable {
    public let executableURL: URL
    public let spawner: any ProcessSpawning
    public let logDirectory: URL?

    public init(
        executableURL: URL = RunnerLauncher.currentExecutableURL(),
        spawner: any ProcessSpawning = FoundationProcessSpawner(),
        logDirectory: URL? = nil
    ) {
        self.executableURL = executableURL
        self.spawner = spawner
        self.logDirectory = logDirectory
    }

    @discardableResult
    public func launch(
        _ spec: RunnerLaunchSpec,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int32 {
        try spawner.spawn(
            executableURL: executableURL,
            arguments: spec.arguments(),
            environment: spec.environment(inheriting: baseEnvironment),
            logURL: logDirectory?.appendingPathComponent("\(spec.profileID.uuidString).log")
        )
    }

    public static func currentExecutableURL() -> URL {
        Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    }
}
