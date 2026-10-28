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
}
