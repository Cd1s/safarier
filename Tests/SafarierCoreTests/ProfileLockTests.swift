import XCTest
@testable import SafarierCore

final class ProfileLockTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarier-lock-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSecondAcquireFailsUntilReleased() throws {
        let id = UUID()
        XCTAssertFalse(ProfileLock.isHeld(profileID: id, in: directory))

        let lock = try ProfileLock.acquire(profileID: id, in: directory)
        XCTAssertTrue(ProfileLock.isHeld(profileID: id, in: directory))
        XCTAssertThrowsError(try ProfileLock.acquire(profileID: id, in: directory)) {
            XCTAssertEqual($0 as? ProfileLockError, .alreadyRunning(id))
        }

        lock.release()
        XCTAssertFalse(ProfileLock.isHeld(profileID: id, in: directory))
        XCTAssertNoThrow(try ProfileLock.acquire(profileID: id, in: directory))
    }

    func testDifferentProfilesDoNotBlockEachOther() throws {
        let a = try ProfileLock.acquire(profileID: UUID(), in: directory)
        let b = try ProfileLock.acquire(profileID: UUID(), in: directory)
        a.release()
        b.release()
    }

    func testManagerLockAcquireMutexPIDAndRelease() throws {
        let workspace = SafarierWorkspace(root: directory)
        XCTAssertFalse(workspace.isManagerRunning())
        XCTAssertNil(workspace.managerPID())

        let lock = try ManagerLock.acquire(in: workspace.locksDirectory)
        XCTAssertTrue(workspace.isManagerRunning())
        XCTAssertEqual(workspace.managerPID(), getpid())

        let attrs = try FileManager.default.attributesOfItem(atPath: lock.fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        XCTAssertThrowsError(try ManagerLock.acquire(in: workspace.locksDirectory)) {
            XCTAssertEqual($0 as? ManagerLockError, .alreadyRunning(pid: getpid()))
        }

        lock.release()
        XCTAssertFalse(workspace.isManagerRunning())
        XCTAssertNil(workspace.managerPID())

        let reacquired = try ManagerLock.acquire(in: workspace.locksDirectory)
        reacquired.release()
    }

    func testManagerLockDoesNotInterfereWithProfileLockOrCleanup() throws {
        let workspace = SafarierWorkspace(root: directory)
        let profileID = UUID()
        let managerLock = try ManagerLock.acquire(in: workspace.locksDirectory)
        defer { managerLock.release() }

        let profileLock = try ProfileLock.acquire(profileID: profileID, in: workspace.locksDirectory)
        XCTAssertTrue(workspace.isManagerRunning())
        XCTAssertTrue(workspace.isRunning(profileID))
        profileLock.release()

        workspace.removeRunnerArtifacts(for: profileID)
        XCTAssertTrue(workspace.isManagerRunning(), "清理环境残留文件不能误删管理器锁")
        XCTAssertTrue(FileManager.default.fileExists(atPath: managerLock.fileURL.path))
    }

    func testManagerWakeupScopeIsolatesDifferentWorkspaces() throws {
        let dirA = directory.appendingPathComponent("ws-a", isDirectory: true)
        let dirB = directory.appendingPathComponent("ws-b", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        let linkToA = directory.appendingPathComponent("ws-a-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkToA, withDestinationURL: dirA)

        let scopeA = ManagerWakeup.workspaceScope(for: dirA)
        let scopeB = ManagerWakeup.workspaceScope(for: dirB)
        let scopeLink = ManagerWakeup.workspaceScope(for: linkToA)

        XCTAssertNotEqual(scopeA, scopeB, "不同工作目录的唤醒隔离键必须互不相等")
        XCTAssertEqual(scopeA, scopeLink, "指向同一工作目录的符号链接应归一化到同一个隔离键")
    }
}
