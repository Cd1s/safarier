import XCTest
import WebKit
@testable import SafarierWebKit
import SafarierCore

final class ProxyConfigurationBuilderTests: XCTestCase {
    @MainActor
    func testPortZeroThrowsInvalid() {
        let settings = ProxySettings(name: "P", kind: .socks5, host: "1.2.3.4", port: 0)
        XCTAssertThrowsError(try ProxyConfigurationBuilder.makeConfiguration(for: settings, password: nil)) { error in
            XCTAssertEqual(error as? ProxyConfigurationError, .invalid(.invalidPort(0)))
        }
    }

    @MainActor
    func testEmptyHostThrowsInvalid() {
        let settings = ProxySettings(name: "P", kind: .httpConnect, host: "", port: 8080)
        XCTAssertThrowsError(try ProxyConfigurationBuilder.makeConfiguration(for: settings, password: nil)) { error in
            XCTAssertEqual(error as? ProxyConfigurationError, .invalid(.emptyHost))
        }
    }

    @MainActor
    func testUsernameWithoutPasswordThrowsMissingPassword() {
        let settings = ProxySettings(name: "P", kind: .socks5, host: "1.2.3.4", port: 1080, username: "u")
        XCTAssertThrowsError(try ProxyConfigurationBuilder.makeConfiguration(for: settings, password: nil)) { error in
            XCTAssertEqual(error as? ProxyConfigurationError, .missingPassword(username: "u"))
        }
    }

    @MainActor
    func testValidSocks5DoesNotThrow() {
        let settings = ProxySettings(name: "P", kind: .socks5, host: "1.2.3.4", port: 1080)
        XCTAssertNoThrow(try ProxyConfigurationBuilder.makeConfiguration(for: settings, password: nil))
    }

    @MainActor
    func testValidHTTPConnectDoesNotThrow() {
        let settings = ProxySettings(name: "P", kind: .httpConnect, host: "proxy.example.com", port: 3128)
        XCTAssertNoThrow(try ProxyConfigurationBuilder.makeConfiguration(for: settings, password: nil))
    }

    @MainActor
    func testCredentialedProxyDoesNotThrow() {
        let settings = ProxySettings(name: "P", kind: .socks5, host: "1.2.3.4", port: 1080, username: "u")
        XCTAssertNoThrow(try ProxyConfigurationBuilder.makeConfiguration(for: settings, password: "pw"))
    }

    @MainActor
    func testApplyAndClearProxyConfigurations() throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let settings = ProxySettings(name: "P", kind: .socks5, host: "1.2.3.4", port: 1080)

        try ProxyConfigurationBuilder.apply(settings, password: nil, to: store)
        XCTAssertEqual(store.proxyConfigurations.count, 1)

        try ProxyConfigurationBuilder.apply(nil, password: nil, to: store)
        XCTAssertEqual(store.proxyConfigurations.count, 0)
    }
}
