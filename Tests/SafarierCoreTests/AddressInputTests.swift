import XCTest
@testable import SafarierCore

final class AddressInputTests: XCTestCase {
    func testURLsAndHostsOpenDirectly() {
        XCTAssertEqual(AddressInput.url(for: "https://example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(AddressInput.url(for: "  example.com  ")?.absoluteString, "https://example.com")
        XCTAssertEqual(AddressInput.url(for: "sub.example.co.uk/path")?.absoluteString, "https://sub.example.co.uk/path")
        XCTAssertEqual(AddressInput.url(for: "localhost:8080")?.absoluteString, "http://localhost:8080")
        XCTAssertEqual(AddressInput.url(for: "127.0.0.1:28777/probe.html")?.absoluteString, "http://127.0.0.1:28777/probe.html")
        XCTAssertEqual(AddressInput.url(for: "[::1]:8080")?.absoluteString, "http://[::1]:8080")
        XCTAssertEqual(AddressInput.url(for: "about:blank")?.absoluteString, "about:blank")
    }

    func testEverythingElseIsSearched() {
        XCTAssertEqual(AddressInput.url(for: "safari 26.2")?.absoluteString, AddressInput.searchURLPrefix + "safari%2026.2")
        XCTAssertTrue(AddressInput.url(for: "苹果 新功能")?.absoluteString.hasPrefix(AddressInput.searchURLPrefix) == true)
        XCTAssertTrue(AddressInput.url(for: "hello")?.absoluteString.hasPrefix(AddressInput.searchURLPrefix) == true)
        XCTAssertTrue(AddressInput.url(for: "a&b=c")?.absoluteString.hasSuffix("a%26b%3Dc") == true)
        XCTAssertTrue(AddressInput.url(for: "version 1.2")?.absoluteString.hasPrefix(AddressInput.searchURLPrefix) == true)
        XCTAssertNil(AddressInput.url(for: "   "))
    }

    func testWebVisibleHardwareFollowsWebKitRules() {
        XCTAssertEqual(MacDeviceModel.webVisibleCPUCores(hostCores: 24), 8)
        XCTAssertEqual(MacDeviceModel.webVisibleCPUCores(hostCores: 8), 8)
        XCTAssertEqual(MacDeviceModel.webVisibleCPUCores(hostCores: 4), 4)
        XCTAssertEqual(MacDeviceModel.webVisibleGPU, "Apple GPU")
    }
}
