import XCTest
import SafarierCore
import SafarierNetwork
@testable import Safarier

/// 图形界面和命令行都能直接粘贴节点链接添加订阅。
@MainActor
final class InlineSubscriptionAddTests: XCTestCase {
    private var root: URL!
    private let link = "ss://2022-blake3-aes-256-gcm:++++////AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRo@ss.example.com:8388#🇸🇬 SS2022"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("inline-add-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testManagerModelAddsPastedLinksAndDeleteRemovesFile() async throws {
        let model = ManagerModel(workspace: SafarierWorkspace(root: root))
        try await model.addSubscription(name: "粘贴的节点", input: link + "\nhysteria2://pw@h.example:443#hy2\n")
        let subscription = try XCTUnwrap(model.subscriptions.first)
        XCTAssertEqual(subscription.nodes.map(\.name), ["🇸🇬 SS2022"])
        XCTAssertTrue(model.isInline(subscription))
        XCTAssertTrue(FileManager.default.fileExists(atPath: subscription.url.path))
        XCTAssertEqual(model.selection, .subscription(subscription.id))
        XCTAssertEqual(model.message?.detail, "导入 1 个节点；跳过 1 个暂不支持的节点（hysteria2 ×1）。")

        model.delete(subscription)
        XCTAssertTrue(model.subscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: subscription.url.path), "删除订阅时一起删掉保存的链接")
    }

    func testManagerModelRejectsGarbageWithoutSaving() async throws {
        let model = ManagerModel(workspace: SafarierWorkspace(root: root))
        do {
            try await model.addSubscription(name: "x", input: "not a link")
            XCTFail("应当报错")
        } catch {
            XCTAssertEqual(error as? InlineSubscriptionError, .unrecognized)
            XCTAssertTrue(DisplayText.describe(error).contains("节点链接"))
        }
        XCTAssertTrue(model.subscriptions.isEmpty)
    }

    func testCLISubAddAcceptsNodeLink() throws {
        setenv("SAFARIER_HOME", root.path, 1)
        defer { unsetenv("SAFARIER_HOME") }
        XCTAssertEqual(ManagerCLI.run(["sub", "add", "--name", "cli", "--url", link]), 0)
        let subscriptions = try SafarierWorkspace(root: root).subscriptions.all()
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.nodes.first?.method, "2022-blake3-aes-256-gcm")
        XCTAssertTrue(InlineSubscription.isInline(try XCTUnwrap(subscriptions.first).url, in: root))

        // 刷新：重新读保存的文件。
        XCTAssertEqual(ManagerCLI.run(["sub", "update"]), 0)
        XCTAssertEqual(try SafarierWorkspace(root: root).subscriptions.all().first?.nodes.count, 1)

        // 认不出来的输入不保存。
        XCTAssertEqual(ManagerCLI.run(["sub", "add", "--name", "bad", "--url", "nonsense"]), 64)
        XCTAssertEqual(try SafarierWorkspace(root: root).subscriptions.all().count, 1)
    }
}
