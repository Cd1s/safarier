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

    /// 复制来的网址夹着看不见的字符（零宽空格、方向标记、BOM、连接符、软连字符）：去掉后照常打开，不变成搜索。
    func testInvisibleCharactersAreRemoved() {
        let inputs = [
            "example.com\u{2060}", "\u{FEFF}example.com", "example.com\u{200F}", "exa\u{200C}mple.com",
            "exa\u{00AD}mple.com", "\u{200B}example.com\u{200B}", "example.com\u{FEFF}",
        ]
        for raw in inputs {
            XCTAssertEqual(AddressInput.url(for: raw)?.absoluteString, "https://example.com", raw.debugDescription)
        }
        XCTAssertEqual(AddressInput.url(for: "https://example.com\u{200E}")?.absoluteString, "https://example.com")
        XCTAssertEqual(AddressInput.url(for: "https://exa\u{200C}mple.com/a")?.absoluteString, "https://example.com/a")
        // 组合表情里的零宽连接符要留着（搜索词原样）。
        XCTAssertTrue(AddressInput.url(for: "👨\u{200D}👩\u{200D}👧 recipe")?.absoluteString.contains("%E2%80%8D") == true)
    }

    /// 中文输入法打出来的全角句号、冒号、斜杠：主机部分换完是 ASCII 才当网址，中文句子照样搜索。
    func testFullwidthPunctuationInAddresses() {
        XCTAssertEqual(AddressInput.url(for: "example。com")?.absoluteString, "https://example.com")
        XCTAssertEqual(AddressInput.url(for: "example．com/ip")?.absoluteString, "https://example.com/ip")
        XCTAssertEqual(AddressInput.url(for: "https：／／example。com")?.absoluteString, "https://example.com")
        XCTAssertTrue(AddressInput.url(for: "你好。世界")?.absoluteString.hasPrefix(AddressInput.searchURLPrefix) == true)
        XCTAssertTrue(AddressInput.url(for: "时间：12。30")?.absoluteString.hasPrefix(AddressInput.searchURLPrefix) == true)
    }

    /// 只写了协议、没有主机的地址不导航（WebKit 只会报「网址无效」）。
    func testSchemeWithoutHostIsRejected() {
        XCTAssertNil(AddressInput.url(for: "https://"))
        XCTAssertNil(AddressInput.url(for: "http:///"))
        XCTAssertTrue(AddressInput.url(for: "mailto:a@example.com")?.absoluteString.hasPrefix(AddressInput.searchURLPrefix) == true, "不是 :// 形式的照常搜索")
    }

    /// 起始网址：和地址栏一样规范化，但不会变成搜索；只认有主机的 http / https。
    func testWebURLForStartPage() {
        XCTAssertEqual(AddressInput.webURL(for: " example.com\u{200B} ")?.absoluteString, "https://example.com")
        XCTAssertEqual(AddressInput.webURL(for: "https://example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(AddressInput.webURL(for: "localhost:8080")?.absoluteString, "http://localhost:8080")
        XCTAssertEqual(AddressInput.webURL(for: "example。com")?.absoluteString, "https://example.com")
        for invalid in ["hello", "example .com", "https://", "ftp://example.com", "about:blank", "", "苹果 官网"] {
            XCTAssertNil(AddressInput.webURL(for: invalid), invalid)
        }
    }

    func testWebVisibleHardwareFollowsWebKitRules() {
        XCTAssertEqual(MacDeviceModel.webVisibleCPUCores(hostCores: 24), 8)
        XCTAssertEqual(MacDeviceModel.webVisibleCPUCores(hostCores: 8), 8)
        XCTAssertEqual(MacDeviceModel.webVisibleCPUCores(hostCores: 4), 4)
        XCTAssertEqual(MacDeviceModel.webVisibleGPU, "Apple GPU")
    }
}
