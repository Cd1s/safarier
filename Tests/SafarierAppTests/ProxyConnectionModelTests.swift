import XCTest
import SafarierCore
import SafarierNetwork
@testable import Safarier

@MainActor
final class ProxyConnectionModelTests: XCTestCase {
    private var root: URL!
    private var workspace: SafarierWorkspace!
    private var credentials: InMemoryCredentialStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        workspace = SafarierWorkspace(root: root)
        credentials = InMemoryCredentialStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func proxy() throws -> ProxySettings {
        let proxy = ProxySettings(name: "Test", kind: .socks5, host: "127.0.0.1", port: 1080, username: "user")
        try workspace.proxies.insert(proxy)
        try credentials.setPassword("secret", forKey: proxy.credentialKey)
        return proxy
    }

    private func waitUntilFinished(_ model: ManagerModel, _ id: UUID) async throws {
        let deadline = Date().addingTimeInterval(2)
        while model.proxyTests[id] == .running, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(model.proxyTests[id], .running)
    }

    func testUsesKeychainPasswordAndLatestMetadataWithoutChangingConfiguration() async throws {
        let original = try proxy()
        let result = ProxyConnectionResult(exitIP: "203.0.113.1", duration: 0.1)
        let calls = expectation(description: "测试只启动一次")
        calls.assertForOverFulfill = true
        let model = ManagerModel(workspace: workspace, credentials: credentials, proxyTester: { proxy, password in
            XCTAssertEqual(proxy.port, 8080)
            XCTAssertEqual(password, "secret")
            calls.fulfill()
            return result
        })
        var current = original
        current.port = 8080
        try workspace.proxies.update(current)
        model.testProxy(original)
        model.testProxy(original)
        await fulfillment(of: [calls], timeout: 2)
        try await waitUntilFinished(model, original.id)
        XCTAssertEqual(model.proxyTests[original.id], .success(result))
        XCTAssertEqual(try workspace.proxies.record(id: original.id), current)
        XCTAssertEqual(try credentials.password(forKey: original.credentialKey), "secret")
        // 仅修改密码、元数据未变也必须清除旧测试结果。
        try model.saveProxy(current, password: "new-secret", isNew: false)
        XCTAssertNil(model.proxyTests[original.id])
    }

    func testMissingPasswordPreventsNetworkRequestAndFailureIsDisplayed() async throws {
        let proxy = try proxy()
        try credentials.removePassword(forKey: proxy.credentialKey)
        let model = ManagerModel(workspace: workspace, credentials: credentials, proxyTester: { _, _ in
            XCTFail("密码缺失时不应发起网络请求")
            throw ProxyConnectionError.connection
        })
        model.testProxy(proxy)
        XCTAssertEqual(model.proxyTests[proxy.id], .failure(ProxyConnectionError.missingPassword.localizedDescription))
        try credentials.setPassword("secret", forKey: proxy.credentialKey)
        let failing = ManagerModel(workspace: workspace, credentials: credentials, proxyTester: { _, _ in
            throw ProxyConnectionError.authentication
        })
        failing.testProxy(proxy)
        try await waitUntilFinished(failing, proxy.id)
        XCTAssertEqual(failing.proxyTests[proxy.id], .failure(ProxyConnectionError.authentication.localizedDescription))
    }

    func testCancelAndReloadDiscardLateResults() async throws {
        let proxy = try proxy()
        for changeConfiguration in [false, true] {
            let started = expectation(description: "已开始")
            let finished = expectation(description: "测试器结束")
            let model = ManagerModel(workspace: workspace, credentials: credentials, proxyTester: { _, _ in
                started.fulfill()
                // 模拟忽略取消、仍返回旧成功结果的执行器。
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch is CancellationError { XCTAssertTrue(Task.isCancelled) }
                finished.fulfill()
                return ProxyConnectionResult(exitIP: "203.0.113.9", duration: 0.2)
            })
            model.testProxy(proxy)
            await fulfillment(of: [started], timeout: 2)
            if changeConfiguration {
                var changed = proxy
                changed.port = 8081
                try workspace.proxies.update(changed)
                model.reload()
            } else {
                model.cancelProxyTest(proxy.id)
            }
            await fulfillment(of: [finished], timeout: 2)
            await Task.yield()
            XCTAssertNil(model.proxyTests[proxy.id])
        }
    }

    func testExecutorCancellationClearsRunningStateAndAllowsRetry() async throws {
        let proxy = try proxy()
        let calls = expectation(description: "取消后可以再次测试")
        calls.expectedFulfillmentCount = 2
        let model = ManagerModel(workspace: workspace, credentials: credentials, proxyTester: { _, _ in
            calls.fulfill()
            throw CancellationError()
        })
        model.testProxy(proxy)
        try await waitUntilFinished(model, proxy.id)
        XCTAssertNil(model.proxyTests[proxy.id])
        model.testProxy(proxy)
        try await waitUntilFinished(model, proxy.id)
        await fulfillment(of: [calls], timeout: 2)
        XCTAssertNil(model.proxyTests[proxy.id])
    }

    func testReloadKeepsResultsOfUnrelatedProxies() async throws {
        let first = try proxy()
        let second = ProxySettings(name: "Other", kind: .socks5, host: "127.0.0.1", port: 1081)
        try workspace.proxies.insert(second)
        let result = ProxyConnectionResult(exitIP: "203.0.113.8", duration: 0.1)
        let model = ManagerModel(workspace: workspace, credentials: credentials, proxyTester: { _, _ in result })
        model.testProxy(first)
        try await waitUntilFinished(model, first.id)
        XCTAssertEqual(model.proxyTests[first.id], .success(result))
        var changed = second
        changed.port = 1082
        try workspace.proxies.update(changed)
        model.reload()
        XCTAssertEqual(model.proxyTests[first.id], .success(result))
        // 别的出口的前置变了，也不影响无关代理。
        let exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "exit.invalid", port: 8080, upstream: .proxy(changed.id))
        try workspace.proxies.insert(exit)
        model.reload()
        model.testProxy(first)
        try await waitUntilFinished(model, first.id)
        changed.port = 1083
        try workspace.proxies.update(changed)
        model.reload()
        XCTAssertEqual(model.proxyTests[first.id], .success(result))
    }

    func testChainTestsUseLocalTunnelAndInvalidateWhenEntryPasswordChanges() async throws {
        guard SingboxProcessManager.locateExecutable() != nil else { throw XCTSkip("本机没有 sing-box") }
        let entry = try proxy()
        let exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "exit.invalid", port: 8080, upstream: .proxy(entry.id))
        try workspace.proxies.insert(exit)
        let result = ProxyConnectionResult(exitIP: "203.0.113.7", duration: 0.1)
        let model = ManagerModel(workspace: workspace, credentials: credentials, proxyTester: { local, password in
            XCTAssertEqual(local.kind, .socks5)
            XCTAssertEqual(local.host, "127.0.0.1")
            XCTAssertNil(local.upstream)
            XCTAssertNil(password)
            return result
        })
        model.testProxy(exit)
        try await waitUntilFinished(model, exit.id)
        XCTAssertEqual(model.proxyTests[exit.id], .success(result))
        try model.saveProxy(entry, password: "new-secret", isNew: false)
        XCTAssertNil(model.proxyTests[exit.id])
        // 失效前置在发起请求之前报错，不会用出口代理单跳测试。
        try workspace.proxies.delete(id: entry.id)
        model.testProxy(exit)
        XCTAssertEqual(model.proxyTests[exit.id], .failure(ProxyChainError.missingProxy.localizedDescription))
    }

    func testSubscriptionRefreshDuringTestDiscardsOldResultWithoutReload() async throws {
        guard SingboxProcessManager.locateExecutable() != nil else { throw XCTSkip("本机没有 sing-box") }
        var subscription = Subscription(name: "Nodes", url: URL(string: "https://example.com/sub")!, nodes: [
            SubscriptionNode(name: "Entry", type: .socks, server: "192.0.2.1", serverPort: 1080),
        ])
        try workspace.subscriptions.insert(subscription)
        let exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "exit.invalid", port: 8080,
                                 upstream: .node(subscriptionID: subscription.id, name: "Entry"))
        try workspace.insertProxy(exit)
        let started = expectation(description: "链路测试已经开始")
        let model = ManagerModel(workspace: workspace, credentials: credentials, proxyTester: { _, _ in
            started.fulfill()
            try await Task.sleep(for: .milliseconds(200))
            return ProxyConnectionResult(exitIP: "203.0.113.7", duration: 0.2)
        })
        model.testProxy(exit)
        await fulfillment(of: [started], timeout: 3)
        // 模拟外部进程刷新：管理器没有收到 reload，节点名相同但服务器已改变。
        subscription.nodes[0].server = "192.0.2.2"
        try workspace.subscriptions.update(subscription)
        try await waitUntilFinished(model, exit.id)
        XCTAssertNil(model.proxyTests[exit.id])
    }
}
