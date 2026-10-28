import XCTest
import Darwin
import SafarierCore
@testable import SafarierNetwork

/// 用本机真实的 sing-box 跑生命周期（没装时跳过）。节点指向一个不存在的地址：sing-box 只在有连接时才拨出站，启动不受影响。
final class SingboxProcessManagerTests: XCTestCase {
    private var root: URL!
    private let node = SubscriptionNode(name: "test", type: .socks, server: "192.0.2.1", serverPort: 1080)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("singbox-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager() throws -> SingboxProcessManager {
        guard let executable = SingboxProcessManager.locateExecutable() else { throw XCTSkip("本机没有 sing-box") }
        return SingboxProcessManager(executableURL: executable, stateDirectory: root)
    }

    private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    func testStartWaitStopRemovesProcessAndStateFiles() throws {
        let manager = try makeManager()
        let id = UUID()

        let pid = try manager.start(profileID: id, node: node)
        let port = try manager.waitUntilReady(profileID: id)

        XCTAssertTrue(manager.isRunning(profileID: id))
        XCTAssertEqual(try manager.port(for: id), port)
        let attributes = try FileManager.default.attributesOfItem(atPath: manager.configurationFileURL(for: id).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let record = try JSONDecoder().decode(SingboxProcessManager.ProcessRecord.self, from: Data(contentsOf: manager.pidFileURL(for: id)))
        XCTAssertEqual(record.pid, pid)
        XCTAssertEqual(record.identity, SingboxProcessManager.processIdentity(of: pid))
        XCTAssertThrowsError(try manager.start(profileID: id, node: node)) {
            XCTAssertEqual($0 as? SingboxProcessError, .alreadyRunning(id))
        }

        try manager.stop(profileID: id)

        XCTAssertFalse(alive(pid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.configurationFileURL(for: id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.pidFileURL(for: id).path))
        XCTAssertTrue(SingboxProcessManager.isPortAvailable(port))
    }

    /// Runner 被 SIGKILL 后 sing-box 还在：管理器在没有 Runner 持锁时按 pid 文件清理；有 Runner 持锁时不动。
    func testReapOrphanOnlyWhenNoRunnerHoldsLock() throws {
        let manager = try makeManager()
        let id = UUID()
        let workspace = SafarierWorkspace(root: root)
        // 让 sing-box 用工作区的状态目录，和 Runner 一致。
        let runnerSide = SingboxProcessManager(executableURL: manager.executableURL, stateDirectory: workspace.singboxDirectory)
        let pid = try runnerSide.start(profileID: id, node: node)
        try runnerSide.waitUntilReady(profileID: id)

        let lock = try ProfileLock.acquire(profileID: id, in: workspace.locksDirectory)
        XCTAssertFalse(SingboxProcessManager.reapOrphanIfIdle(profileID: id, workspace: workspace))
        XCTAssertTrue(alive(pid))
        lock.release()

        XCTAssertTrue(SingboxProcessManager.reapOrphanIfIdle(profileID: id, workspace: workspace))
        XCTAssertFalse(alive(pid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runnerSide.pidFileURL(for: id).path))
    }

    func testStalePidFileOfUnrelatedProcessIsIgnored() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 自己的 pid：活着，但不是 sing-box，不能被杀。
        try "\(getpid())\n".write(to: SingboxProcessManager.pidFileURL(for: id, in: root), atomically: true, encoding: .utf8)
        XCTAssertFalse(SingboxProcessManager.reapOrphan(profileID: id, in: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SingboxProcessManager.pidFileURL(for: id, in: root).path))
    }

    /// 用本次测试创建的休眠进程核验身份，不依赖本机安装 sing-box，也不触碰已有进程。
    private func withRecordedProcess(_ body: (Process, UUID, SingboxProcessManager.ProcessRecord) throws -> Void) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let id = UUID()
        let identity = try XCTUnwrap(SingboxProcessManager.processIdentity(of: process.processIdentifier))
        let record = SingboxProcessManager.ProcessRecord(
            pid: process.processIdentifier, identity: identity,
            configurationPath: SingboxProcessManager.configurationFileURL(for: id, in: root).standardizedFileURL.path
        )
        try body(process, id, record)
    }

    func testMatchingProcessIdentityIsReaped() throws {
        try withRecordedProcess { process, id, record in
            try JSONEncoder().encode(record).write(to: SingboxProcessManager.pidFileURL(for: id, in: root))
            try Data().write(to: SingboxProcessManager.configurationFileURL(for: id, in: root))
            XCTAssertTrue(SingboxProcessManager.reapOrphan(profileID: id, in: root))
            process.waitUntilExit()
            XCTAssertFalse(process.isRunning)
            XCTAssertFalse(FileManager.default.fileExists(atPath: record.configurationPath))
        }
    }

    func testReusedPIDAndMismatchedPathsAreNotReaped() throws {
        try withRecordedProcess { process, id, record in
            var reused = record
            reused.identity.startMicroseconds += 1
            var wrongExecutable = record
            wrongExecutable.identity.executablePath += ".other"
            var wrongConfiguration = record
            wrongConfiguration.configurationPath += ".other"
            for stale in [reused, wrongExecutable, wrongConfiguration] {
                try JSONEncoder().encode(stale).write(to: SingboxProcessManager.pidFileURL(for: id, in: root))
                XCTAssertFalse(SingboxProcessManager.reapOrphan(profileID: id, in: root))
                XCTAssertTrue(process.isRunning)
            }
        }
    }

    func testLegacyAndMalformedRecordsNeverSignalLiveProcess() throws {
        try withRecordedProcess { process, id, _ in
            for text in ["\(process.processIdentifier)\n", "{\"pid\":\(process.processIdentifier)}", "invalid"] {
                try Data(text.utf8).write(to: SingboxProcessManager.pidFileURL(for: id, in: root))
                XCTAssertFalse(SingboxProcessManager.reapOrphan(profileID: id, in: root))
                XCTAssertTrue(process.isRunning)
            }
        }
    }

    func testEarlyExitIsReported() throws {
        // /usr/bin/false 当作 sing-box：马上退出。
        let manager = SingboxProcessManager(executableURL: URL(fileURLWithPath: "/usr/bin/false"), stateDirectory: root)
        let id = UUID()
        try manager.start(profileID: id, node: node)
        XCTAssertThrowsError(try manager.waitUntilReady(profileID: id, timeout: 5)) {
            XCTAssertEqual($0 as? SingboxProcessError, .exitedEarly(status: 1))
        }
        try? manager.stop(profileID: id)
    }

    func testPortSelectionSkipsPortsInUse() throws {
        // 占住一个端口，范围只给它和下一个。
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                Darwin.bind(fd, pointer, length) == 0 && Darwin.listen(fd, 1) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        XCTAssertTrue(bound)
        let busy = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertFalse(SingboxProcessManager.isPortAvailable(busy))

        let range = busy < 65535 ? busy...(busy + 1) : (busy - 1)...busy
        let manager = SingboxProcessManager(executableURL: URL(fileURLWithPath: "/usr/bin/false"), stateDirectory: root, portRange: range)
        let ports = (0..<6).map { _ in try? manager.port(for: UUID()) }
        XCTAssertFalse(ports.contains(busy))
    }

    func testBundledHelperPathIsNextToAppExecutable() {
        let app = URL(fileURLWithPath: "/Applications/Safarier.app/Contents/MacOS/Safarier")
        XCTAssertEqual(SingboxProcessManager.bundledExecutableURL(mainExecutable: app)?.path,
                       "/Applications/Safarier.app/Contents/Helpers/sing-box")
        XCTAssertNil(SingboxProcessManager.bundledExecutableURL(mainExecutable: URL(fileURLWithPath: "/usr/local/bin/safarier")))
        XCTAssertNil(SingboxProcessManager.bundledExecutableURL(mainExecutable: URL(fileURLWithPath: "/tmp/.build/release/Safarier")))
    }

    /// 自带的优先于 Homebrew 和 PATH；SAFARIER_SINGBOX 优先于自带的；自带的不存在时退回系统里的。
    func testLookupOrderPrefersOverrideThenBundledHelper() throws {
        let helpers = root.appendingPathComponent("Safarier.app/Contents/Helpers", isDirectory: true)
        let onPath = root.appendingPathComponent("bin", isDirectory: true)
        for directory in [helpers, onPath] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let binary = directory.appendingPathComponent("sing-box")
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let bundled = helpers.appendingPathComponent("sing-box")
        let environment = ["PATH": onPath.path]

        XCTAssertEqual(SingboxProcessManager.locateExecutable(environment: environment, bundledExecutable: bundled), bundled)
        XCTAssertEqual(SingboxProcessManager.locateExecutable(environment: environment.merging(["SAFARIER_SINGBOX": "/opt/sb"]) { $1 },
                                                              bundledExecutable: bundled)?.path, "/opt/sb")
        let fallback = try XCTUnwrap(SingboxProcessManager.locateExecutable(environment: environment,
                                                                            bundledExecutable: root.appendingPathComponent("missing")))
        XCTAssertNotEqual(fallback, bundled)
    }

    func testMissingExecutableErrorExplainsHowToFixIt() {
        let text = "\(SingboxProcessError.executableNotFound(URL(fileURLWithPath: "/opt/homebrew/bin/sing-box")))"
        XCTAssertTrue(text.contains("找不到 sing-box"), text)
        XCTAssertTrue(text.contains("brew install sing-box") && text.contains("SAFARIER_SINGBOX"), text)
    }

    /// 只去掉自带那一份的隔离标记；已经放行过的（0x40）不算隔离。
    func testQuarantineIsClearedOnlyForBundledHelper() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundled = root.appendingPathComponent("sing-box")
        let other = root.appendingPathComponent("other")
        for (url, flags) in [(bundled, "0083"), (other, "0083")] {
            try Data().write(to: url)
            let value = "\(flags);6addb12b;Safari;"
            XCTAssertEqual(setxattr(url.path, SingboxProcessManager.quarantineAttribute, value, value.utf8.count, 0, 0), 0)
        }
        XCTAssertTrue(SingboxProcessManager.isQuarantined(bundled))

        XCTAssertNoThrow(try SingboxProcessManager.clearQuarantine(of: bundled, bundled: bundled))
        XCTAssertNoThrow(try SingboxProcessManager.clearQuarantine(of: other, bundled: bundled))
        XCTAssertFalse(SingboxProcessManager.isQuarantined(bundled))
        XCTAssertTrue(SingboxProcessManager.isQuarantined(other))

        let approved = "00c3;6addb12b;Safari;"
        XCTAssertEqual(setxattr(other.path, SingboxProcessManager.quarantineAttribute, approved, approved.utf8.count, 0, 0), 0)
        XCTAssertFalse(SingboxProcessManager.isQuarantined(other))
    }
}
