import XCTest
import WebKit
@testable import SafarierWebKit
import SafarierCore

final class DataStoreManagerTests: XCTestCase {
    private var usedPersistentIDs: [UUID] = []

    @MainActor
    func testEphemeralProfileGetsNonPersistentStore() {
        let manager = DataStoreManager()
        let profile = Profile(name: "Eph", mode: .ephemeral)

        let first = manager.dataStore(for: profile)
        let second = manager.dataStore(for: profile)

        XCTAssertFalse(first.isPersistent)
        XCTAssertFalse(first === second)
    }

    @MainActor
    func testPersistentProfileGetsStoreWithProfileID() {
        let manager = DataStoreManager()
        let profile = Profile(name: "Per", mode: .persistent)
        usedPersistentIDs.append(profile.id)

        let store = manager.dataStore(for: profile)

        XCTAssertTrue(store.isPersistent)
        XCTAssertEqual(store.identifier, profile.id)
    }

    override func tearDown() async throws {
        let ids = usedPersistentIDs
        usedPersistentIDs = []
        let manager = await DataStoreManager()
        for id in ids {
            try? await manager.removePersistentData(for: id)
        }
        try await super.tearDown()
    }
}
