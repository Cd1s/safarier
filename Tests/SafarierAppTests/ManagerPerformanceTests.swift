import XCTest
import Darwin
import SafarierCore
@testable import SafarierNetwork
@testable import Safarier

@MainActor
final class ManagerPerformanceTests: XCTestCase {
    func testOrphanCleanupKeepsMainActorResponsiveAndDoesNotAppearAsRunner() async throws {
        try await checkQueuedLaunch(editDuringCleanup: false)
    }

    func testQueuedLaunchRejectsDraftCreatedDuringCleanup() async throws {
        try await checkQueuedLaunch(editDuringCleanup: true)
    }

    private func checkQueuedLaunch(editDuringCleanup: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manager-perf-\(UUID())")
        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "orphan", mode: .ephemeral)
        try workspace.profiles.insert(profile)
        defer { try? FileManager.default.removeItem(at: root) }

        // exec 保留被忽略的 SIGTERM；使用本次测试创建的进程，不依赖 sing-box。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; exec /bin/sleep 30"]
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let readyDeadline = Date().addingTimeInterval(5)
        while SingboxProcessManager.processIdentity(of: process.processIdentifier)?.executablePath.hasSuffix("/sleep") != true,
              Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let identity = try XCTUnwrap(SingboxProcessManager.processIdentity(of: process.processIdentifier))
        XCTAssertTrue(identity.executablePath.hasSuffix("/sleep"))
        let directory = workspace.singboxDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = SingboxProcessManager.configurationFileURL(for: profile.id, in: directory)
        let pidFile = SingboxProcessManager.pidFileURL(for: profile.id, in: directory)
        let record = SingboxProcessManager.ProcessRecord(pid: process.processIdentifier, identity: identity,
                                                        configurationPath: config.standardizedFileURL.path)
        try Data().write(to: config)
        try JSONEncoder().encode(record).write(to: pidFile)

        let started = Date()
        let model = ManagerModel(workspace: workspace)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "初始化不等待两秒清理")
        let lockDeadline = Date().addingTimeInterval(1)
        while workspace.runnerPID(profile.id) != getpid(), Date() < lockDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(workspace.runnerPID(profile.id), getpid(), "清理仍在后台持锁等待进程退出")
        XCTAssertTrue(process.isRunning)
        for _ in 0..<3 { model.refreshRunningState() }
        XCTAssertFalse(model.running.contains(profile.id), "清理锁不能误认成 Runner")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "清理期间主线程还能刷新状态")

        model.launch(profile)
        XCTAssertEqual(model.runState(profile.id), .starting, "清理期间启动只排队，不争抢锁")
        XCTAssertNil(model.message)
        // 等待期间新建草稿或外部删除环境，都不应再拉起 Runner。
        if editDuringCleanup {
            model.editor(for: profile).values.name = "Unsaved draft"
        } else {
            try workspace.profiles.delete(id: profile.id)
            model.reload()
        }

        let finishedDeadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: pidFile.path), Date() < finishedDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        XCTAssertFalse(workspace.isRunning(profile.id), "清理完成后释放锁")
        let launchDeadline = Date().addingTimeInterval(1)
        while model.starting.contains(profile.id), Date() < launchDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.starting.contains(profile.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.runnerLogURL(for: profile.id).path))
        if editDuringCleanup {
            XCTAssertNotNil(model.message)
            XCTAssertTrue(model.editor(for: profile).hasChanges)
            XCTAssertEqual(try workspace.profiles.record(id: profile.id), profile)
        } else {
            XCTAssertNil(model.message)
        }
    }

    func testLogTailIsBoundedAndRespectsLaunchOffset() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-tail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        let previous = Data("上次运行的日志\n".utf8)
        let current = "第一行\n第二行\n第三行\n"
        try (previous + Data(current.utf8)).write(to: url)
        XCTAssertEqual(ManagerModel.logTail(url, from: UInt64(previous.count), maxLines: 2), "第二行\n第三行")
        XCTAssertNil(ManagerModel.logTail(url, from: UInt64(previous.count + current.utf8.count)))
        XCTAssertNil(ManagerModel.logTail(url, from: UInt64.max))
        XCTAssertNil(ManagerModel.logTail(url, from: 0, maxLines: 0))

        let hugeLine = String(repeating: "中", count: 100_000)
        try Data((hugeLine + "\n最后错误\n").utf8).write(to: url)
        XCTAssertEqual(ManagerModel.logTail(url, from: 0), "最后错误", "截断的首行不混入诊断")
        try Data(hugeLine.utf8).write(to: url)
        let tail = try XCTUnwrap(ManagerModel.logTail(url, from: 0))
        XCTAssertLessThanOrEqual(tail.utf8.count, 64 * 1024 + 3, "没有换行的日志也受字节预算限制")
        XCTAssertTrue(tail.hasSuffix("中"), "截到 UTF-8 字符中间仍保留后续文本")
    }
}
