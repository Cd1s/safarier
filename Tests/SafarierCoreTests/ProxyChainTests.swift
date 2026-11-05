import XCTest
@testable import SafarierCore

final class ProxyChainTests: XCTestCase {
    /// 旧版忽略不认识的字段，但仍检查文档版本；必须依靠版本号阻止它把链路当成单跳。
    private struct LegacyProxy: Codable {
        let id: UUID
        let name: String
        let kind: ProxyKind
        let host: String
        let port: Int
        let username: String?
    }

    private func legacyRead(_ data: Data) throws -> [LegacyProxy] {
        let document = try JSONDecoder().decode(JSONDocumentStore<LegacyProxy>.Document.self, from: data)
        guard document.version <= 1 else { throw JSONDocumentStore<LegacyProxy>.StoreError.unsupportedVersion(document.version) }
        return document.records
    }

    func testChainedDocumentsBlockLegacyReadersForEveryUpstreamSource() throws {
        let entry = ProxySettings(name: "Entry", kind: .socks5, host: "192.0.2.1", port: 1080)
        for upstream in [ProxyUpstream.proxy(entry.id), .node(subscriptionID: UUID(), name: "Node"),
                         .custom(#"{"type":"socks","server":"192.0.2.3","server_port":1080}"#)] {
            let exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "192.0.2.2", port: 8080, upstream: upstream)
            let data = try JSONDocumentStore<ProxySettings>.encode([entry, exit])
            XCTAssertThrowsError(try legacyRead(data)) {
                XCTAssertEqual($0 as? JSONDocumentStore<LegacyProxy>.StoreError, .unsupportedVersion(2))
            }
            XCTAssertEqual(try JSONDocumentStore<ProxySettings>.decode(data), [entry, exit])
        }
    }

    func testLegacyProxyFileUpgradesOnSaveAndKeepsProtectionAcrossOtherEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = SafarierWorkspace(root: root)
        let entry = ProxySettings(name: "Entry", kind: .socks5, host: "192.0.2.1", port: 1080)
        var exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "192.0.2.2", port: 8080)
        let file = root.appendingPathComponent("proxies.json")
        // 主线的旧格式仍可读；保存前置后，整个文件必须阻止旧版读取。
        let legacyData = try JSONEncoder().encode(JSONDocumentStore<ProxySettings>.Document(version: 1, records: [entry, exit]))
        try legacyData.write(to: file)
        XCTAssertEqual(try workspace.proxies.all(), [entry, exit])
        XCTAssertEqual(try legacyRead(legacyData).count, 2)
        exit.upstream = .proxy(entry.id)
        try workspace.updateProxy(exit)
        XCTAssertThrowsError(try legacyRead(Data(contentsOf: file)))
        var renamed = entry
        renamed.name = "Renamed entry"
        try workspace.updateProxy(renamed)
        XCTAssertThrowsError(try legacyRead(Data(contentsOf: file)))
        XCTAssertEqual(try workspace.proxies.all(), [renamed, exit])
        // 只有所有前置都已显式移除，才可以安全地供旧版使用。
        exit.upstream = nil
        try workspace.updateProxy(exit)
        XCTAssertEqual(try legacyRead(Data(contentsOf: file)).count, 2)
    }

    func testVersionTwoIsAcceptedOnlyForProxiesAndFutureVersionsStillFail() throws {
        let proxies = try JSONEncoder().encode(JSONDocumentStore<ProxySettings>.Document(version: 3, records: []))
        XCTAssertThrowsError(try JSONDocumentStore<ProxySettings>.decode(proxies)) {
            XCTAssertEqual($0 as? JSONDocumentStore<ProxySettings>.StoreError, .unsupportedVersion(3))
        }
        let profiles = try JSONEncoder().encode(JSONDocumentStore<Profile>.Document(version: 2, records: []))
        XCTAssertThrowsError(try JSONDocumentStore<Profile>.decode(profiles)) {
            XCTAssertEqual($0 as? JSONDocumentStore<Profile>.StoreError, .unsupportedVersion(2))
        }
        let unchanged = try JSONDecoder().decode(JSONDocumentStore<Profile>.Document.self,
                                                 from: JSONDocumentStore<Profile>.encode([]))
        XCTAssertEqual(unchanged.version, 1)
    }

    func testOldProxyDecodesAndCustomUpstreamUsesPrivateStorage() throws {
        let id = UUID()
        let legacy = """
        {"id":"\(id)","name":"Legacy","kind":"socks5","host":"192.0.2.1","port":1080}
        """
        var proxy = try JSONDecoder().decode(ProxySettings.self, from: Data(legacy.utf8))
        XCTAssertNil(proxy.upstream)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        for upstream in [ProxyUpstream.proxy(UUID()), .node(subscriptionID: UUID(), name: "Node"), .custom("test-credential")] {
            proxy.upstream = upstream
            let data = try JSONEncoder().encode(proxy)
            XCTAssertEqual(try JSONDecoder().decode(ProxySettings.self, from: data), proxy)
        }
        try workspace.proxies.insert(proxy)
        XCTAssertEqual(try workspace.proxies.record(id: id), proxy)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("proxies.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testRejectsMissingReferencesSelfCyclesAndLongerChains() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        var entry = ProxySettings(name: "Entry", kind: .socks5, host: "192.0.2.1", port: 1080)
        var exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "192.0.2.2", port: 8080, upstream: .proxy(entry.id))
        XCTAssertThrowsError(try workspace.validateProxyChain(exit)) { XCTAssertEqual($0 as? ProxyChainError, .missingProxy) }
        try workspace.proxies.insert(entry)
        XCTAssertNoThrow(try workspace.validateProxyChain(exit))
        try workspace.proxies.insert(exit)
        entry.upstream = .proxy(exit.id)
        XCTAssertThrowsError(try workspace.validateProxyChain(entry)) { XCTAssertEqual($0 as? ProxyChainError, .usedAsUpstream) }
        exit.upstream = .proxy(exit.id)
        XCTAssertThrowsError(try workspace.validateProxyChain(exit)) { XCTAssertEqual($0 as? ProxyChainError, .selfReference) }
        let third = ProxySettings(name: "Third", kind: .socks5, host: "192.0.2.3", port: 1080, upstream: .proxy(exit.id))
        XCTAssertThrowsError(try workspace.validateProxyChain(third)) { XCTAssertEqual($0 as? ProxyChainError, .multipleHops) }
        XCTAssertEqual(try workspace.proxies(usingProxyID: entry.id).map(\.id), [exit.id])
        let id = UUID()
        exit.upstream = .node(subscriptionID: id, name: "Missing")
        XCTAssertThrowsError(try workspace.validateProxyChain(exit)) { XCTAssertEqual($0 as? ProxyChainError, .missingSubscription) }
        try workspace.subscriptions.insert(Subscription(id: id, name: "Subscription", url: URL(string: "https://example.com/sub")!, nodes: []))
        XCTAssertThrowsError(try workspace.validateProxyChain(exit)) { XCTAssertEqual($0 as? ProxyChainError, .missingNode) }
    }

    /// 校验在写入的同一把锁里读取记录：写入前别人已经把 A 设为前置时，给 A 加前置必须失败。
    func testSavingChecksUpstreamUsageAgainstLockedRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        var a = ProxySettings(name: "A", kind: .socks5, host: "192.0.2.1", port: 1080)
        let b = ProxySettings(name: "B", kind: .socks5, host: "192.0.2.2", port: 1080)
        let c = ProxySettings(name: "C", kind: .socks5, host: "192.0.2.3", port: 1080)
        for proxy in [a, b, c] { try workspace.insertProxy(proxy) }
        a.upstream = .proxy(c.id)
        // 模拟另一个进程：在本进程校验通过之后、写入之前把 B 的前置设成 A。
        XCTAssertNoThrow(try workspace.validateProxyChain(a))
        var chainedB = b
        chainedB.upstream = .proxy(a.id)
        try workspace.updateProxy(chainedB)
        XCTAssertThrowsError(try workspace.updateProxy(a)) { XCTAssertEqual($0 as? ProxyChainError, .usedAsUpstream) }
        XCTAssertNil(try workspace.proxies.record(id: a.id)?.upstream)
        XCTAssertThrowsError(try workspace.insertProxy(ProxySettings(name: "D", kind: .socks5, host: "192.0.2.4", port: 1080, upstream: .proxy(b.id)))) {
            XCTAssertEqual($0 as? ProxyChainError, .multipleHops)
        }
    }

    func testIPv6BracketsAreStripped() {
        XCTAssertEqual("[2001:db8::1]".withoutIPv6Brackets, "2001:db8::1")
        XCTAssertEqual("2001:db8::1".withoutIPv6Brackets, "2001:db8::1")
        XCTAssertEqual("proxy.example".withoutIPv6Brackets, "proxy.example")
    }
}
