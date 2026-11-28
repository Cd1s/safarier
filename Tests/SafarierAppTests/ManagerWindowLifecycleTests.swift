import AppKit
import XCTest
import SafarierCore
@testable import Safarier

@MainActor
final class ManagerWindowLifecycleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manager-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var workspace: SafarierWorkspace { SafarierWorkspace(root: root) }

    func testManagerLauncherWakesRunningManagerInsteadOfSpawningNewInstance() {
        var notifiedScope: String?
        var activatedPID: Int32?
        var openedBundle: URL?
        var spawnedExecutable: URL?

        let env = ManagerLauncher.Environment(
            managerPID: { 4242 },
            isProcessAlive: { $0 == 4242 },
            postWakeupNotification: { notifiedScope = $0 },
            activateProcess: { activatedPID = $0; return true },
            bundleURL: { URL(fileURLWithPath: "/Applications/Safarier.app") },
            executableURL: { URL(fileURLWithPath: "/tmp/Safarier") },
            processEnvironment: { ["SAFARIER_HOME": self.root.path] },
            openAppBundle: { url, _ in openedBundle = url },
            spawnExecutable: { url, _ in spawnedExecutable = url }
        )

        let result = ManagerLauncher.openOrWakeManager(workspace: workspace, environment: env)

        XCTAssertEqual(result, .wokeRunningManager(pid: 4242))
        XCTAssertEqual(notifiedScope, workspace.managerWakeupScope)
        XCTAssertEqual(activatedPID, 4242)
        XCTAssertNil(openedBundle)
        XCTAssertNil(spawnedExecutable)
    }

    func testManagerLauncherOpensAppBundleWhenManagerIsNotRunning() {
        let appURL = URL(fileURLWithPath: "/Applications/Safarier.app")
        var openedBundle: URL?
        var passedEnv: [String: String]?
        var notified = false

        let env = ManagerLauncher.Environment(
            managerPID: { nil },
            isProcessAlive: { _ in false },
            postWakeupNotification: { _ in notified = true },
            activateProcess: { _ in false },
            bundleURL: { appURL },
            executableURL: { URL(fileURLWithPath: "/Applications/Safarier.app/Contents/MacOS/Safarier") },
            processEnvironment: { ["SAFARIER_HOME": self.root.path] },
            openAppBundle: { url, env in
                openedBundle = url
                passedEnv = env
            },
            spawnExecutable: { _, _ in XCTFail("打包成 .app 时不应走裸二进制回落") }
        )

        let result = ManagerLauncher.openOrWakeManager(workspace: workspace, environment: env)

        XCTAssertEqual(result, .launchedAppBundle(appURL))
        XCTAssertEqual(openedBundle, appURL)
        XCTAssertEqual(passedEnv?["SAFARIER_HOME"], root.path)
        XCTAssertFalse(notified)
    }

    func testManagerLauncherFallsBackToRawExecutableWhenNotInAppBundle() {
        let binaryURL = URL(fileURLWithPath: "/tmp/build/Safarier")
        var spawnedURL: URL?
        var spawnedEnv: [String: String]?

        let env = ManagerLauncher.Environment(
            managerPID: { 9999 },
            isProcessAlive: { _ in false },
            postWakeupNotification: { _ in XCTFail("进程已退出时不应只发唤醒通知") },
            activateProcess: { _ in false },
            bundleURL: { URL(fileURLWithPath: "/tmp/build") },
            executableURL: { binaryURL },
            processEnvironment: { ["SAFARIER_HOME": self.root.path] },
            openAppBundle: { _, _ in XCTFail("非 .app 包不应调 openApplication") },
            spawnExecutable: { url, env in
                spawnedURL = url
                spawnedEnv = env
            }
        )

        let result = ManagerLauncher.openOrWakeManager(workspace: workspace, environment: env)

        XCTAssertEqual(result, .launchedRawExecutable(binaryURL))
        XCTAssertEqual(spawnedURL, binaryURL)
        XCTAssertEqual(spawnedEnv?["SAFARIER_HOME"], root.path)
    }

    func testManagerAppDelegateStaysAliveAfterLastWindowClosedAndReopens() throws {
        _ = NSApplication.shared
        let delegate = ManagerAppDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp), "关闭管理窗口后进程应保持运行")

        var reopenedCount = 0
        delegate.registerOpenWindow { reopenedCount += 1 }
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertEqual(reopenedCount, 1, "无可见窗口收到 reopen 时应唤出主窗口")

        // 程序坞右键菜单应提供「打开环境管理器」，且触发主窗唤出。
        let dockMenu = try XCTUnwrap(delegate.applicationDockMenu(NSApp))
        let openItem = try XCTUnwrap(dockMenu.items.first { $0.title == L10n.text("打开环境管理器") })
        XCTAssertEqual(openItem.action, #selector(ManagerAppDelegate.openManagerFromDock(_:)))
        XCTAssertTrue(openItem.target === delegate)
        delegate.openManagerFromDock(nil)
        XCTAssertEqual(reopenedCount, 2)
    }

    func testManagerAppDelegateRespondsOnlyToOwnWorkspaceWakeupNotification() throws {
        _ = NSApplication.shared
        let otherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("manager-lifecycle-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherRoot) }

        let delegate = ManagerAppDelegate()
        var openedCount = 0
        delegate.registerOpenWindow { openedCount += 1 }
        delegate.startObservingWakeup(scope: workspace.managerWakeupScope)
        defer { delegate.stopObservingWakeup() }

        // 另一个工作目录的通知不应误触发当前管理器。
        ManagerLauncher.postWakeupNotification(scope: SafarierWorkspace(root: otherRoot).managerWakeupScope)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(openedCount, 0)

        // 同一工作目录的通知应准确唤醒。
        ManagerLauncher.postWakeupNotification(scope: workspace.managerWakeupScope)
        let deadline = Date().addingTimeInterval(2)
        while openedCount == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(openedCount, 1)
    }

    func testManagerGUILockLifecycleAndRelaunchReleaseRollback() throws {
        defer { ManagerGUI.releaseManagerLock() }
        ManagerGUI.releaseManagerLock()

        XCTAssertTrue(ManagerGUI.acquireManagerLock(for: workspace))
        XCTAssertTrue(workspace.isManagerRunning())
        XCTAssertEqual(workspace.managerPID(), getpid())

        // 模拟重启过程：先释放锁，launch 期间另一个实例可以拿锁；若 launch 抛错则旧进程重新拿回锁。
        enum DummyError: Error { case boom }
        var lockHeldDuringLaunch: Bool?
        XCTAssertThrowsError(try ManagerGUI.withLockReleasedForRelaunch(workspace: workspace) {
            lockHeldDuringLaunch = workspace.isManagerRunning()
            throw DummyError.boom
        })
        XCTAssertEqual(lockHeldDuringLaunch, false, "拉起新实例前必须先释放单实例锁")
        XCTAssertTrue(workspace.isManagerRunning(), "拉起失败后旧实例应重新拿回锁")

        // 正常重启成功时保持释放状态，不阻止新实例拿锁。
        ManagerGUI.withLockReleasedForRelaunch(workspace: workspace) {
            XCTAssertFalse(workspace.isManagerRunning())
        }
        XCTAssertFalse(workspace.isManagerRunning())

        // 已有锁存在时，再次尝试抢锁应触发已运行回调并返回 false。
        let existingLock = try ManagerLock.acquire(in: workspace.locksDirectory)
        defer { existingLock.release() }
        var detectedPID: Int32?
        XCTAssertFalse(ManagerGUI.acquireManagerLock(for: workspace) { detectedPID = $0 })
        XCTAssertEqual(detectedPID, getpid())
    }

    func testBrowserMenuAndDockMenuExposeOpenManagerEntry() throws {
        _ = NSApplication.shared
        let mainMenu = BrowserMenu.make()
        let windowMenu = try XCTUnwrap(mainMenu.items.first { $0.title == L10n.text("窗口") }?.submenu)
        let openItem = try XCTUnwrap(windowMenu.items.first { $0.action == #selector(BrowserActions.openManager(_:)) })
        XCTAssertEqual(openItem.title, L10n.text("打开环境管理器"))
        XCTAssertEqual(openItem.keyEquivalent, "0")
        XCTAssertEqual(openItem.keyEquivalentModifierMask, [.command, .option])

        // 即使当前没有任何可见浏览窗口，「打开环境管理器」菜单项也应保持可用，且 Dock 右键菜单有对应入口。
        let session = try BrowserFixesTests.makeSession(Profile(name: "dock", mode: .ephemeral))
        XCTAssertTrue(session.openControllers.isEmpty)
        XCTAssertTrue(session.validateMenuItem(openItem))

        let dockMenu = try XCTUnwrap(session.applicationDockMenu(NSApp))
        let dockItem = try XCTUnwrap(dockMenu.items.first { $0.title == L10n.text("打开环境管理器") })
        XCTAssertEqual(dockItem.action, #selector(BrowserSession.openManager(_:)))
        XCTAssertTrue(dockItem.target === session)
    }
}
