import XCTest
import SafarierCore
import SafarierNetwork
@testable import Safarier

/// Round 3 管理器 / 命令行修复：--node none 保留独立代理、删除环境清理残留文件、刷新拿到空列表不覆盖节点、编辑器自定义留空报错。
@MainActor
final class ManagerFixesTests: XCTestCase {
    private var root: URL!
    private let link = "ss://2022-blake3-aes-128-gcm:++++////AQIDBAUGBwgJCg==@ss.example.com:8388#node-a"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("SAFARIER_HOME", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("SAFARIER_HOME")
        try? FileManager.default.removeItem(at: root)
    }

    private var workspace: SafarierWorkspace { SafarierWorkspace(root: root) }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// `profile update --node none` 只解绑订阅节点：独立代理的环境不受影响，节点环境变成直连。
    func testNodeNoneKeepsStandaloneProxy() throws {
        let proxy = ProxySettings(name: "p", kind: .socks5, host: "127.0.0.1", port: 1080)
        try workspace.proxies.insert(proxy)
        let proxied = Profile(name: "proxied", mode: .ephemeral, proxyID: proxy.id)
        try workspace.profiles.insert(proxied)
        XCTAssertEqual(ManagerCLI.run(["profile", "update", proxied.id.uuidString, "--node", "none"]), 0)
        XCTAssertEqual(try workspace.profiles.record(id: proxied.id)?.proxyID, proxy.id, "独立代理保留")

        XCTAssertEqual(ManagerCLI.run(["sub", "add", "--name", "s", "--url", link]), 0)
        let subscription = try XCTUnwrap(workspace.subscriptions.all().first)
        let bound = Profile(name: "bound", mode: .ephemeral, subscriptionID: subscription.id, nodeName: "node-a")
        try workspace.profiles.insert(bound)
        XCTAssertEqual(ManagerCLI.run(["profile", "update", bound.id.uuidString, "--node", "none"]), 0)
        let updated = try XCTUnwrap(workspace.profiles.record(id: bound.id))
        XCTAssertNil(updated.subscriptionID)
        XCTAssertNil(updated.nodeName)
        XCTAssertNil(updated.proxyID)
    }

    func testCLIProfileDeleteRemovesArtifacts() throws {
        let profile = Profile(name: "gone", mode: .ephemeral)
        try workspace.profiles.insert(profile)
        let log = workspace.runnerLogURL(for: profile.id)
        let lock = workspace.locksDirectory.appendingPathComponent("\(profile.id.uuidString).lock")
        for url in [log, lock] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        XCTAssertEqual(ManagerCLI.run(["profile", "delete", profile.id.uuidString]), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }

    func testGUIProfileDeleteRemovesArtifacts() throws {
        let profile = Profile(name: "gone", mode: .ephemeral)
        try workspace.profiles.insert(profile)
        let log = workspace.runnerLogURL(for: profile.id)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: log)
        let model = ManagerModel(workspace: workspace)
        model.delete(profile, purgeData: false)
        spin(until: { model.profiles.isEmpty && !FileManager.default.fileExists(atPath: log.path) })
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    /// 订阅这次返回的内容里没有节点：命令行和图形界面都不拿空列表覆盖已有节点。
    func testRefreshWithNoNodesKeepsCachedNodes() throws {
        XCTAssertEqual(ManagerCLI.run(["sub", "add", "--name", "s", "--url", link]), 0)
        let subscription = try XCTUnwrap(workspace.subscriptions.all().first)
        try Data("# 服务器这次什么都没给\n".utf8).write(to: subscription.url)

        XCTAssertEqual(ManagerCLI.run(["sub", "update", subscription.id.uuidString]), 1, "一个都没更新时返回失败")
        XCTAssertEqual(try workspace.subscriptions.record(id: subscription.id)?.nodes.map(\.name), ["node-a"])

        let model = ManagerModel(workspace: workspace)
        model.refresh(subscription)
        spin(until: { model.message != nil })
        XCTAssertEqual(model.message?.title, "刷新「s」没有拿到节点")
        XCTAssertEqual(model.subscriptions.first?.nodes.map(\.name), ["node-a"])
        XCTAssertEqual(try workspace.subscriptions.record(id: subscription.id)?.nodes.count, 1)
    }

    /// 编辑器里语言 / 时区选了「自定义」却没填：报错，不悄悄存成「跟随系统」。
    func testCustomRegionMustNotBeEmpty() {
        typealias E = ProfileEditorView
        XCTAssertNotNil(E.customRegionError(languageSource: .custom, languages: " , ", timeZoneSource: .system, timeZone: ""))
        XCTAssertNotNil(E.customRegionError(languageSource: .system, languages: "", timeZoneSource: .custom, timeZone: "  "))
        XCTAssertNil(E.customRegionError(languageSource: .custom, languages: "th-TH, th", timeZoneSource: .custom, timeZone: "Asia/Bangkok"))
        XCTAssertNil(E.customRegionError(languageSource: .proxy, languages: "", timeZoneSource: .system, timeZone: ""))
    }
}
