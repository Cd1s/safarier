import XCTest
import SafarierCore
@testable import SafarierNetwork

final class ProxyChainBuilderTests: XCTestCase {
    func testAllUpstreamSourcesUseManagedRoutingAndFreshReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        let credentials = InMemoryCredentialStore()
        let entry = ProxySettings(name: "Entry", kind: .socks5, host: "192.0.2.1", port: 1080, username: "entry-user")
        try workspace.proxies.insert(entry)
        try credentials.setPassword("entry-secret", forKey: entry.credentialKey)
        var exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "exit.example.com", port: 8080, username: "exit-user", upstream: .proxy(entry.id))
        try credentials.setPassword("exit-secret", forKey: exit.credentialKey)
        var chain = try XCTUnwrap(ProxyChainBuilder.resolve(exit, in: workspace, credentials: credentials))
        let config = try chain.configuration(inboundPort: 23456)
        XCTAssertEqual(config.outbounds.count, 2)
        XCTAssertEqual(config.outbounds[0]["tag"], .string("upstream"))
        XCTAssertEqual(config.outbounds[0]["password"], .string("entry-secret"))
        XCTAssertEqual(config.outbounds[1]["detour"], .string("upstream"))
        XCTAssertEqual(config.outbounds[1]["password"], .string("exit-secret"))
        XCTAssertEqual(config.route["final"], config.outbounds[1]["tag"])
        XCTAssertFalse(config.outbounds.contains { $0["type"] == .string("direct") })
        XCTAssertEqual(config.inbounds[0]["listen"], .string("127.0.0.1"))

        var node = SubscriptionNode(name: "Node", type: .vless, server: "192.0.2.3", serverPort: 443, uuid: "00000000-0000-0000-0000-000000000001")
        var subscription = Subscription(name: "Subscription", url: URL(string: "https://example.com/sub")!, nodes: [node])
        try workspace.subscriptions.insert(subscription)
        exit.upstream = .node(subscriptionID: subscription.id, name: node.name)
        chain = try XCTUnwrap(ProxyChainBuilder.resolve(exit, in: workspace, credentials: credentials))
        XCTAssertEqual(chain.entry["type"], .string("vless"))
        // 刷新后节点 ID 改变，但仍按名字解析最新服务器。
        node = SubscriptionNode(name: "Node", type: .socks, server: "192.0.2.4", serverPort: 1081)
        subscription.nodes = [node]
        try workspace.subscriptions.update(subscription)
        chain = try XCTUnwrap(ProxyChainBuilder.resolve(exit, in: workspace, credentials: credentials))
        XCTAssertEqual(chain.entry["server"], .string("192.0.2.4"))
        subscription.nodes = []
        try workspace.subscriptions.update(subscription)
        XCTAssertThrowsError(try ProxyChainBuilder.resolve(exit, in: workspace, credentials: credentials)) { XCTAssertEqual($0 as? ProxyChainError, .missingNode) }

        exit.upstream = .custom(#"{"type":"socks","tag":"user-tag","server":"192.0.2.5","server_port":1080}"#)
        chain = try XCTUnwrap(ProxyChainBuilder.resolve(exit, in: workspace, credentials: credentials))
        XCTAssertEqual(try chain.configuration(inboundPort: 23456).outbounds[0]["tag"], .string("upstream"))
        exit.upstream = .custom(#"{"type":"socks","server":"192.0.2.5","server_port":1080,"detour":"direct"}"#)
        XCTAssertThrowsError(try ProxyChainBuilder.resolve(exit, in: workspace, credentials: credentials))
    }

    func testMissingCredentialsAndDeletedUpstreamCannotBecomeSingleHop() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        let credentials = InMemoryCredentialStore()
        let entry = ProxySettings(name: "Entry", kind: .socks5, host: "192.0.2.1", port: 1080, username: "user")
        try workspace.proxies.insert(entry)
        let exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "192.0.2.2", port: 8080, upstream: .proxy(entry.id))
        XCTAssertThrowsError(try ProxyChainBuilder.resolve(exit, in: workspace, credentials: credentials)) {
            guard case ProxyConnectionError.missingPassword = $0 else { return XCTFail("Expected missing credentials") }
        }
        try workspace.proxies.delete(id: entry.id)
        XCTAssertThrowsError(try ProxyChainBuilder.resolve(exit, in: workspace, credentials: credentials)) { XCTAssertEqual($0 as? ProxyChainError, .missingProxy) }
    }

    func testBracketedIPv6UsesIPAddressInsteadOfDomainResolution() throws {
        let proxy = ProxySettings(name: "IPv6", kind: .socks5, host: "[2001:db8::1]", port: 1080)
        XCTAssertEqual(try ProxyChainBuilder.outbound(proxy, credentials: InMemoryCredentialStore())["server"], .string("2001:db8::1"))
    }
}
