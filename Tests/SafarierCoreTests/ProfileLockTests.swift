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
}
