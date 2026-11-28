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
    func testProfilesSyncNotificationScopeIsolatesDifferentWorkspaces() throws {
        let dirA = directory.appendingPathComponent("ws-a", isDirectory: true)
        let dirB = directory.appendingPathComponent("ws-b", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        let linkToA = directory.appendingPathComponent("ws-a-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkToA, withDestinationURL: dirA)

        let scopeA = ProfilesSyncNotification.workspaceScope(for: dirA)
        let scopeB = ProfilesSyncNotification.workspaceScope(for: dirB)
        let scopeLink = ProfilesSyncNotification.workspaceScope(for: linkToA)

        XCTAssertNotEqual(scopeA, scopeB, "不同工作目录的同步隔离键必须互不相等")
        XCTAssertEqual(scopeA, scopeLink, "指向同一工作目录的符号链接应归一化到同一个隔离键")
    }
}
