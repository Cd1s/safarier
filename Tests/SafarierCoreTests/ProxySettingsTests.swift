import XCTest
@testable import SafarierCore

final class ProxySettingsTests: XCTestCase {
    func testValidProxyPasses() {
        let proxy = ProxySettings(name: "Home", kind: .socks5, host: "1.2.3.4", port: 1080)
        XCTAssertNoThrow(try proxy.validate())
    }

    func testEmptyHostThrows() {
        let proxy = ProxySettings(name: "P", kind: .httpConnect, host: "", port: 8080)
        XCTAssertThrowsError(try proxy.validate()) { error in
            XCTAssertEqual(error as? ProxyValidationError, .emptyHost)
        }
    }

    func testHostWithSchemeThrows() {
        let proxy = ProxySettings(name: "P", kind: .socks5, host: "socks5://1.2.3.4", port: 1080)
        XCTAssertThrowsError(try proxy.validate()) { error in
            XCTAssertEqual(error as? ProxyValidationError, .invalidHost("socks5://1.2.3.4"))
        }
    }

    func testHostWithWhitespaceThrows() {
        let proxy = ProxySettings(name: "P", kind: .socks5, host: "a b", port: 1080)
        XCTAssertThrowsError(try proxy.validate()) { error in
            XCTAssertEqual(error as? ProxyValidationError, .invalidHost("a b"))
        }
    }

    func testPortZeroThrows() {
        let proxy = ProxySettings(name: "P", kind: .socks5, host: "1.2.3.4", port: 0)
        XCTAssertThrowsError(try proxy.validate()) { error in
            XCTAssertEqual(error as? ProxyValidationError, .invalidPort(0))
        }
    }

    func testPortTooLargeThrows() {
        let proxy = ProxySettings(name: "P", kind: .socks5, host: "1.2.3.4", port: 70000)
        XCTAssertThrowsError(try proxy.validate()) { error in
            XCTAssertEqual(error as? ProxyValidationError, .invalidPort(70000))
        }
    }

    func testCredentialKeyUsesProxyPrefix() {
        let proxy = ProxySettings(name: "P", kind: .socks5, host: "1.2.3.4", port: 1080)
        XCTAssertTrue(proxy.credentialKey.hasPrefix("proxy."))
        XCTAssertEqual(proxy.credentialKey, "proxy." + proxy.id.uuidString)
    }
}
