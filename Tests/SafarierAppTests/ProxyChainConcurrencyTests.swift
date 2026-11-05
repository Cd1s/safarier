import XCTest
import SafarierCore
import SafarierNetwork
@testable import Safarier

/// 在读取凭据时插入另一进程的写入，稳定覆盖校验与后续操作之间的窗口。
private final class InterleavingCredentialStore: CredentialStore, @unchecked Sendable {
    let storage = InMemoryCredentialStore()
    private let lock = NSLock()
    private var didRead = false
    private let beforeFirstRead: @Sendable () throws -> Void

    init(beforeFirstRead: @escaping @Sendable () throws -> Void) {
        self.beforeFirstRead = beforeFirstRead
    }

    func password(forKey key: String) throws -> String? {
        lock.lock()
        let firstRead = !didRead
        didRead = true
        lock.unlock()
        if firstRead { try beforeFirstRead() }
        return try storage.password(forKey: key)
    }

    func setPassword(_ password: String, forKey key: String) throws {
        try storage.setPassword(password, forKey: key)
    }

    func removePassword(forKey key: String) throws {
        try storage.removePassword(forKey: key)
    }
}

@MainActor
final class ProxyChainConcurrencyTests: XCTestCase {
    func testDeleteRechecksNewUpstreamReferencesAndRestoresPassword() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        let otherWriter = SafarierWorkspace(root: root)
        let entry = ProxySettings(name: "Entry", kind: .socks5, host: "192.0.2.1", port: 1080, username: "user")
        let exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "192.0.2.2", port: 8080, upstream: .proxy(entry.id))
        try workspace.insertProxy(entry)
        let credentials = InterleavingCredentialStore {
            // 删除的初次引用检查已经通过；另一个进程此时保存一条引用。
            try otherWriter.insertProxy(exit)
        }
        try credentials.setPassword("original-password", forKey: entry.credentialKey)
        let model = ManagerModel(workspace: workspace, credentials: credentials)

        XCTAssertThrowsError(try model.deleteProxy(entry)) { error in
            guard case ProxyManagementError.usedAsUpstream(let names) = error else {
                return XCTFail("应当因新增的前置引用拒绝删除：\(error)")
            }
            XCTAssertEqual(names, [exit.name])
        }
        XCTAssertEqual(try workspace.proxies.record(id: entry.id), entry)
        XCTAssertEqual(try workspace.proxies.record(id: exit.id), exit)
        XCTAssertEqual(try credentials.password(forKey: entry.credentialKey), "original-password")
        XCTAssertNoThrow(try workspace.validateProxyChain(exit))
    }

    func testRefreshDuringChainResolutionDiscardsResultForOriginalNode() async throws {
        guard SingboxProcessManager.locateExecutable() != nil else { throw XCTSkip("本机没有 sing-box") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        let node = SubscriptionNode(name: "Entry", type: .socks, server: "192.0.2.1", serverPort: 1080)
        let subscription = Subscription(name: "Nodes", url: URL(string: "https://example.com/sub")!, nodes: [node])
        try workspace.subscriptions.insert(subscription)
        let exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "exit.invalid", port: 8080,
                                 username: "user", upstream: .node(subscriptionID: subscription.id, name: node.name))
        try workspace.insertProxy(exit)
        let credentials = InterleavingCredentialStore {
            // 链路已经捕获旧节点，在读取出口密码时模拟订阅刷新。
            var refreshed = subscription
            refreshed.nodes[0].server = "192.0.2.2"
            try SafarierWorkspace(root: root).subscriptions.update(refreshed)
        }
        try credentials.setPassword("exit-password", forKey: exit.credentialKey)
        let tested = expectation(description: "旧链路完成测试")
        let model = ManagerModel(workspace: workspace, credentials: credentials, proxyTester: { _, _ in
            tested.fulfill()
            return ProxyConnectionResult(exitIP: "203.0.113.7", duration: 0.1)
        })

        model.testProxy(exit)
        await fulfillment(of: [tested], timeout: 3)
        let deadline = Date().addingTimeInterval(3)
        while model.proxyTests[exit.id] == .running, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try workspace.subscriptions.record(id: subscription.id)?.nodes[0].server, "192.0.2.2")
        XCTAssertNil(model.proxyTests[exit.id], "旧节点的结果不能标为刷新后节点的成功状态")
    }
}
