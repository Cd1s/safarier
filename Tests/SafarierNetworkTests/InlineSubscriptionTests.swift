import XCTest
import SafarierCore
@testable import SafarierNetwork

/// 直接粘贴的节点链接当作订阅：原文存进 subscriptions-inline/<id>.txt，订阅地址是它的 file:// URL，刷新时重新读。
final class InlineSubscriptionTests: XCTestCase {
    private var root: URL!
    private static let key16 = "++++////AQIDBAUGBwgJCg=="

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("inline-sub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSubscriptionURLDetection() {
        XCTAssertEqual(InlineSubscription.subscriptionURL(from: " https://sub.example.com/a?token=x \n")?.host, "sub.example.com")
        XCTAssertEqual(InlineSubscription.subscriptionURL(from: "file:///tmp/nodes.txt")?.scheme, "file")
        XCTAssertNil(InlineSubscription.subscriptionURL(from: "ss://2022-blake3-aes-128-gcm:\(Self.key16)@ss.example.com:8388#a"))
        XCTAssertNil(InlineSubscription.subscriptionURL(from: "vless://00000000-0000-0000-0000-000000000001@v.example:443#v"))
        XCTAssertNil(InlineSubscription.subscriptionURL(from: "https://a.example/1\nhttps://b.example/2"), "多行不是一个订阅网址")
        XCTAssertNil(InlineSubscription.subscriptionURL(from: Data("trojan://p@t.example:443#t".utf8).base64EncodedString()))
        XCTAssertNil(InlineSubscription.subscriptionURL(from: ""))
    }

    /// 一条 SS2022 链接就能当订阅：保存原文、通过订阅校验、刷新（重新读文件）得到同样的节点。
    func testStoreSingleSS2022LinkAndRefreshReadsItBack() async throws {
        let id = UUID()
        let link = "ss://2022-blake3-aes-128-gcm:----____AQIDBAUGBwgJCg@ss.example.com:8388#🇯🇵 SS2022"
        let stored = try InlineSubscription.store("  \(link)\n", id: id, in: root)
        XCTAssertTrue(stored.url.isFileURL)
        XCTAssertEqual(stored.url.lastPathComponent, "\(id.uuidString).txt")
        XCTAssertEqual(stored.url.deletingLastPathComponent().lastPathComponent, InlineSubscription.directoryName)
        XCTAssertEqual(try String(contentsOf: stored.url, encoding: .utf8), link + "\n")
        XCTAssertEqual(stored.result.nodes.map(\.name), ["🇯🇵 SS2022"])
        XCTAssertEqual(stored.result.nodes.first?.password, Self.key16, "密钥已规范化")

        let attributes = try FileManager.default.attributesOfItem(atPath: stored.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "链接里有节点密码，只给自己读")

        let subscription = Subscription(id: id, name: "粘贴", url: stored.url, updatedAt: Date(), nodes: stored.result.nodes)
        XCTAssertNoThrow(try subscription.validate())
        let refreshed = try await SubscriptionFetcher().fetch(from: stored.url)
        XCTAssertEqual(refreshed.map(\.name), ["🇯🇵 SS2022"])
        XCTAssertEqual(refreshed.first?.password, Self.key16)
    }

    func testStoreMultipleLinksAndBase64Text() throws {
        let lines = [
            "ss2022://2022-blake3-aes-128-gcm:\(Self.key16)@ss.example.com:8388#a",
            "hysteria2://pw@h.example:443#skip",
            "vless://00000000-0000-0000-0000-000000000001@v.example:443?security=tls#b",
        ].joined(separator: "\n")
        let multi = try InlineSubscription.store(lines, id: UUID(), in: root)
        XCTAssertEqual(multi.result.nodes.map(\.name), ["a", "b"])
        XCTAssertEqual(multi.result.skippedSchemes, ["hysteria2": 1])

        let base64 = try InlineSubscription.store(Data(lines.utf8).base64EncodedString(), id: UUID(), in: root)
        XCTAssertEqual(base64.result.nodes.count, 2)
    }

    func testStoreRejectsInputWithoutNodesAndWritesNothing() throws {
        XCTAssertThrowsError(try InlineSubscription.store("sub.example.com/path", id: UUID(), in: root)) {
            XCTAssertEqual($0 as? InlineSubscriptionError, .unrecognized)
        }
        XCTAssertThrowsError(try InlineSubscription.store("# 只有注释", id: UUID(), in: root)) {
            XCTAssertEqual($0 as? InlineSubscriptionError, .noNodes)
        }
        XCTAssertThrowsError(try InlineSubscription.store("hysteria2://pw@h.example:443#x", id: UUID(), in: root)) {
            XCTAssertEqual($0 as? SubscriptionParseError, .unsupportedScheme("hysteria2"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: InlineSubscription.directory(in: root).path), "解析失败时不留文件")
    }

    func testRemoveOnlyTouchesInlineFiles() throws {
        let stored = try InlineSubscription.store("trojan://p@t.example:443#t", id: UUID(), in: root)
        XCTAssertTrue(InlineSubscription.isInline(stored.url, in: root))
        let outside = root.appendingPathComponent("mine.txt")
        try Data("trojan://p@t.example:443#t".utf8).write(to: outside)
        XCTAssertFalse(InlineSubscription.isInline(outside, in: root))
        XCTAssertFalse(InlineSubscription.isInline(URL(string: "https://sub.example.com/x")!, in: root))

        InlineSubscription.remove(outside, in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "用户自己的 file:// 订阅不删")
        InlineSubscription.remove(stored.url, in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.url.path))
    }
}
