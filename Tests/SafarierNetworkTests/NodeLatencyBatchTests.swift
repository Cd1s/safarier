import XCTest
import SafarierCore
@testable import SafarierNetwork

@MainActor
final class NodeLatencyBatchTests: XCTestCase {
    private func executable() throws -> URL {
        guard let executable = SingboxProcessManager.locateExecutable() else {
            throw XCTSkip("Set SAFARIER_SINGBOX to run the loopback batch fixture")
        }
        return executable
    }

    private func nodes(_ fixture: HTTPSProxyFixture, count: Int) throws -> [SubscriptionNode] {
        try (0..<count).map { index in
            let kind = ["http", "socks", "https-proxy"][index % 3]
            return SubscriptionNode(name: "Node \(index)", type: kind == "socks" ? .socks : .http,
                                    server: "127.0.0.1", serverPort: try XCTUnwrap(fixture.ports[kind]),
                                    username: "test-user", password: "test-secret", tls: kind == "https-proxy",
                                    serverName: "localhost", parameters: kind == "https-proxy" ? ["insecure": "1"] : [:])
        }
    }

    private func check(_ nodes: [SubscriptionNode], fixture: HTTPSProxyFixture, path: String = "trace",
                       timeout: TimeInterval = 5, results: Results) async throws {
        try await ProxyConnectionTester.check(
            nodes: nodes, executableURL: executable(),
            target: URL(string: "https://localhost:\(try XCTUnwrap(fixture.ports["https"]))/\(path)")!,
            certificate: fixture.root.appendingPathComponent("cert.pem"), timeout: timeout,
            stateDirectory: fixture.root.appendingPathComponent("batch-state")
        ) { id, result in await results.append(id, result) }
    }

    func testAllRequestsReachTargetBeforeAnyCompleteUsingOneCore() async throws {
        let fixture = try HTTPSProxyFixture()
        defer { fixture.stop() }
        let nodes = try nodes(fixture, count: 226)
        let results = Results()
        let task = Task { try await check(nodes + [nodes[0]], fixture: fixture, path: "barrier", results: results) }
        defer { task.cancel() }
        try await waitForRequests(nodes.count, fixture: fixture)
        let earlyCount = await results.count
        XCTAssertEqual(earlyCount, 0)
        let state = fixture.root.appendingPathComponent("batch-state")
        let files = try FileManager.default.subpathsOfDirectory(atPath: state.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertEqual(files.filter { $0.hasSuffix(".pid") }.count, 1)
        let configPath = try XCTUnwrap(files.first { $0.hasSuffix(".json") })
        let configURL = state.appendingPathComponent(configPath)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data().write(to: fixture.root.appendingPathComponent("barrier-release"))
        try await task.value
        let values = await results.values
        XCTAssertEqual(values.count, nodes.count)
        for value in values.values { XCTAssertEqual(try value.get().exitIP, "203.0.113.7") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: state.path).isEmpty)
    }

    func testFastSuccessStreamsBeforeTimeoutAndBadAuthenticationDoesNotFailPeers() async throws {
        let fixture = try HTTPSProxyFixture()
        defer { fixture.stop() }
        var nodes = try nodes(fixture, count: 3)
        nodes[1].password = "wrong"
        nodes[2] = SubscriptionNode(name: "Slow", type: .http, server: "127.0.0.1",
                                    serverPort: try XCTUnwrap(fixture.ports["stall-http"]))
        let results = Results()
        let task = Task { try await check(nodes, fixture: fixture, timeout: 2, results: results) }
        defer { task.cancel() }
        let deadline = Date().addingTimeInterval(1.5)
        while await results.values[nodes[0].id] == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let early = await results.values
        XCTAssertEqual(try XCTUnwrap(early[nodes[0].id]).get().exitIP, "203.0.113.7")
        XCTAssertNil(early[nodes[2].id], "Fast results must appear before the slow request times out")
        try await task.value
        let values = await results.values
        XCTAssertEqual(values.count, 3)
        XCTAssertThrowsError(try XCTUnwrap(values[nodes[1].id]).get())
        XCTAssertThrowsError(try XCTUnwrap(values[nodes[2].id]).get()) {
            guard case ProxyConnectionError.timeout = $0 else { return XCTFail("Expected timeout") }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("batch-state").path).isEmpty)
    }

    func testCancellationCleansBatchProcessAndPrivateFiles() async throws {
        let fixture = try HTTPSProxyFixture()
        defer { fixture.stop() }
        let nodes = try nodes(fixture, count: 6)
        let results = Results()
        let task = Task { try await check(nodes, fixture: fixture, path: "barrier", results: results) }
        try await waitForRequests(nodes.count, fixture: fixture)
        task.cancel()
        do { try await task.value; XCTFail("Cancellation must not finish successfully") }
        catch is CancellationError { }
        let count = await results.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("batch-state").path).isEmpty)
    }

    func testInvalidNodeIsReportedWithoutBlockingValidPeers() async throws {
        let fixture = try HTTPSProxyFixture()
        defer { fixture.stop() }
        var nodes = try nodes(fixture, count: 2)
        nodes[1].serverPort = 0
        let results = Results()
        try await check(nodes, fixture: fixture, results: results)
        let values = await results.values
        XCTAssertEqual(try XCTUnwrap(values[nodes[0].id]).get().exitIP, "203.0.113.7")
        XCTAssertThrowsError(try XCTUnwrap(values[nodes[1].id]).get())
    }

    func testHTTPSSubscriptionNodeWorksAsUpstreamAndFailsClosed() async throws {
        let fixture = try HTTPSProxyFixture()
        defer { fixture.stop() }
        let workspace = SafarierWorkspace(root: fixture.root.appendingPathComponent("workspace"))
        let node = SubscriptionNode(name: "HTTPS upstream", type: .http, server: "127.0.0.1",
                                    serverPort: try XCTUnwrap(fixture.ports["entry-https"]),
                                    username: "test-user", password: "test-secret", tls: true,
                                    serverName: "localhost", parameters: ["insecure": "1"])
        let subscription = Subscription(name: "Fixture", url: URL(string: "https://example.com/sub")!, nodes: [node])
        try workspace.subscriptions.insert(subscription)
        let exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "exit.invalid",
                                 port: try XCTUnwrap(fixture.ports["http"]), username: "test-user",
                                 upstream: .node(subscriptionID: subscription.id, name: node.name))
        let credentials = InMemoryCredentialStore()
        try credentials.setPassword("test-secret", forKey: exit.credentialKey)
        let chain = try XCTUnwrap(ProxyChainBuilder.resolve(exit, in: workspace, credentials: credentials))
        let target = URL(string: "https://localhost:\(try XCTUnwrap(fixture.ports["https"]))/trace")!
        let tester: ProxyConnectionTester.Test = { proxy, password in
            try await ProxyConnectionTester.check(proxy: proxy, password: password, target: target,
                                                  certificate: fixture.root.appendingPathComponent("cert.pem"), timeout: 2)
        }
        let result = try await ProxyConnectionTester.check(chain: chain, executableURL: executable(), using: tester)
        XCTAssertEqual(result.exitIP, "203.0.113.7")
        let before = try Data(contentsOf: fixture.root.appendingPathComponent("target-requests"))
        try Data().write(to: fixture.root.appendingPathComponent("entry-offline"))
        do {
            _ = try await ProxyConnectionTester.check(chain: chain, executableURL: executable(), using: tester)
            XCTFail("An unavailable HTTPS upstream must not bypass the chain")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("target-requests")), before)
    }

    private func waitForRequests(_ count: Int, fixture: HTTPSProxyFixture) async throws {
        let deadline = Date().addingTimeInterval(4)
        var actual = 0
        while Date() < deadline {
            actual = (try? String(contentsOf: fixture.root.appendingPathComponent("target-requests"), encoding: .utf8))?
                .split(separator: "\n").count ?? 0
            if actual >= count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(actual, count, "All requests must start while earlier requests are still waiting")
    }

    private actor Results {
        var values: [UUID: Result<ProxyConnectionResult, Error>] = [:]
        var count: Int { values.count }
        func append(_ id: UUID, _ value: Result<ProxyConnectionResult, Error>) { values[id] = value }
    }
}
