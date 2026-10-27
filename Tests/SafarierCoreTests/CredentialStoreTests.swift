import XCTest
@testable import SafarierCore

final class CredentialStoreTests: XCTestCase {
    func testMissingKeyReturnsNil() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.password(forKey: "proxy.missing"))
    }

    func testSetThenGetReturnsPassword() throws {
        let store = InMemoryCredentialStore()
        try store.setPassword("secret", forKey: "proxy.a")
        XCTAssertEqual(try store.password(forKey: "proxy.a"), "secret")
    }

    func testSetOverwritesExistingPassword() throws {
        let store = InMemoryCredentialStore()
        try store.setPassword("old", forKey: "proxy.a")
        try store.setPassword("new", forKey: "proxy.a")
        XCTAssertEqual(try store.password(forKey: "proxy.a"), "new")
    }

    func testRemoveDeletesPassword() throws {
        let store = InMemoryCredentialStore()
        try store.setPassword("secret", forKey: "proxy.a")
        try store.removePassword(forKey: "proxy.a")
        XCTAssertNil(try store.password(forKey: "proxy.a"))
    }

    func testRemoveMissingKeyDoesNotThrow() {
        let store = InMemoryCredentialStore()
        XCTAssertNoThrow(try store.removePassword(forKey: "proxy.missing"))
    }
}
