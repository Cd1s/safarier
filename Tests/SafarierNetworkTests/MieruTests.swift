import Foundation
import Darwin
import XCTest
import SafarierCore
@testable import SafarierNetwork

final class MieruTests: XCTestCase {
    private func node() throws -> SubscriptionNode {
        try XCTUnwrap(SubscriptionParser.parse(ClashSubscriptionParserTests.mixedProtocols).first { $0.type == .mieru })
    }

    func testNativeConfigPreservesAuthenticationAndDisablesLANAndRPC() throws {
        var node = try node()
        for transport in ["TCP", "UDP"] {
            node.transport = transport
            let data = try MieruConfigBuilder.build(inboundPort: 12345, node: node)
            let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(config["rpcPort"] as? Int, 0)
            XCTAssertEqual(config["socks5Port"] as? Int, 12345)
            XCTAssertEqual(config["socks5ListenLAN"] as? Bool, false)
            XCTAssertNil(config["httpProxyPort"])
            let profile = try XCTUnwrap((config["profiles"] as? [[String: Any]])?.first)
            XCTAssertEqual(profile["user"] as? [String: String], ["name": "sample-user", "password": "sample:password"])
            XCTAssertEqual(profile["multiplexing"] as? [String: String], ["level": "MULTIPLEXING_LOW"])
            let server = try XCTUnwrap((profile["servers"] as? [[String: Any]])?.first)
            XCTAssertEqual(server["domainName"] as? String, "mieru.example.com")
            let binding = try XCTUnwrap((server["portBindings"] as? [[String: Any]])?.first)
            XCTAssertEqual(binding["protocol"] as? String, transport)
        }
        node.server = "2001:db8::1"
        let data = try MieruConfigBuilder.build(inboundPort: 12345, node: node)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("ipAddress"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("domainName"))
    }

    func testMieruCannotAccidentallyBecomeAnUnsupportedSingboxOutbound() throws {
        let node = try node()
        XCTAssertThrowsError(try SingboxConfigBuilder.build(inboundPort: 12345, node: node)) {
            XCTAssertEqual($0 as? SingboxConfigError, .mieruRequiresBridge)
        }
        XCTAssertThrowsError(try MieruConfigBuilder.build(inboundPort: 0, node: node))
        var invalid = node
        invalid.username = nil
        XCTAssertThrowsError(try MieruConfigBuilder.build(inboundPort: 12345, node: invalid))
    }

    func testMieruLookupHonorsExplicitOverride() {
        XCTAssertEqual(MieruConfigBuilder.locateExecutable(environment: ["SAFARIER_MIERU": "/example/mieru"], bundledExecutable: nil)?.path, "/example/mieru")
    }

    private func requireMieru() throws {
        guard let executable = MieruConfigBuilder.locateExecutable(), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Set SAFARIER_MIERU to run native Mieru lifecycle checks")
        }
    }

    func testRealMieruStartsPrivatelyAndStopsWithoutLeavingCredentials() throws {
        try requireMieru()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SingboxProcessManager(stateDirectory: directory)
        defer { manager.stopAll() }
        let id = UUID()
        try manager.start(profileID: id, node: node())
        let port = try manager.waitUntilReady(profileID: id)
        XCTAssertFalse(SingboxProcessManager.isPortAvailable(port))
        let configURL = manager.configurationFileURL(for: id)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try manager.start(profileID: id, node: node()))
        try manager.stop(profileID: id)
        XCTAssertFalse(manager.isRunning(profileID: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertTrue(SingboxProcessManager.isPortAvailable(port))
    }

    func testRealMieruUpstreamUsesTwoLocalProcessesAndReapsBoth() throws {
        try requireMieru()
        guard SingboxProcessManager.locateExecutable() != nil else { throw XCTSkip("sing-box missing") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SafarierWorkspace(root: root)
        let node = try node()
        let subscription = Subscription(name: "Example", url: URL(string: "https://example.com/sub")!, nodes: [node])
        try workspace.subscriptions.insert(subscription)
        let exit = ProxySettings(name: "Exit", kind: .socks5, host: "exit.invalid", port: 1080,
                                 upstream: .node(subscriptionID: subscription.id, name: node.name))
        let chain = try XCTUnwrap(ProxyChainBuilder.resolve(exit, in: workspace, credentials: InMemoryCredentialStore()))
        XCTAssertThrowsError(try chain.configuration(inboundPort: 12345))
        let manager = SingboxProcessManager(stateDirectory: workspace.singboxDirectory)
        defer { manager.stopAll() }
        let id = UUID()
        try manager.start(profileID: id, chain: chain)
        _ = try manager.waitUntilReady(profileID: id)
        let config = try JSONDecoder().decode(SingboxConfiguration.self, from: Data(contentsOf: manager.configurationFileURL(for: id)))
        XCTAssertEqual(config.outbounds.count, 2)
        XCTAssertEqual(config.outbounds[0]["type"], .string("socks"))
        XCTAssertEqual(config.outbounds[0]["server"], .string("127.0.0.1"))
        XCTAssertEqual(config.outbounds[1]["detour"], .string("upstream"))
        XCTAssertEqual(config.route, ["final": .string("proxy")])
        XCTAssertFalse(config.outbounds.contains { $0["type"] == .string("direct") })
        let bridgePIDFile = workspace.singboxDirectory.appendingPathComponent("mieru/\(id.uuidString).pid")
        let oldBridge = try JSONDecoder().decode(SingboxProcessManager.ProcessRecord.self, from: Data(contentsOf: bridgePIDFile))
        kill(try XCTUnwrap(manager.processIdentifier(for: id)), SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while manager.isRunning(profileID: id), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(manager.isRunning(profileID: id))
        try manager.start(profileID: id, chain: chain)
        _ = try manager.waitUntilReady(profileID: id)
        XCTAssertNil(SingboxProcessManager.processIdentity(of: oldBridge.pid))
        let bridge = try JSONDecoder().decode(SingboxProcessManager.ProcessRecord.self, from: Data(contentsOf: bridgePIDFile))
        XCTAssertNotEqual(bridge.pid, oldBridge.pid)
        XCTAssertNotNil(SingboxProcessManager.processIdentity(of: bridge.pid))
        XCTAssertTrue(SingboxProcessManager.reapOrphan(profileID: id, in: workspace.singboxDirectory))
        XCTAssertNil(SingboxProcessManager.processIdentity(of: bridge.pid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.configurationPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.configurationFileURL(for: id).path))
    }

    func testNodeLatencyUsesLoopbackAndCleansUpAfterFailure() async throws {
        try requireMieru()
        let observed = LocalPort()
        do {
            _ = try await ProxyConnectionTester.check(node: node()) { proxy, password in
                XCTAssertEqual(proxy.host, "127.0.0.1")
                XCTAssertNil(proxy.upstream)
                XCTAssertNil(password)
                await observed.set(proxy.port)
                throw ProxyConnectionError.connection
            }
            XCTFail("Expected failure")
        } catch ProxyConnectionError.connection { }
        let port = await observed.value
        XCTAssertTrue(SingboxProcessManager.isPortAvailable(try XCTUnwrap(port)))
    }

    @MainActor
    func testNativeMieruAndTwoHopHTTPSFailClosedAgainstLocalServer() async throws {
        try requireMieru()
        guard let serverPath = ProcessInfo.processInfo.environment["SAFARIER_MITA"],
              FileManager.default.isExecutableFile(atPath: serverPath),
              SingboxProcessManager.locateExecutable() != nil else {
            throw XCTSkip("Set SAFARIER_MITA to run the local Mieru server integration check")
        }
        let fixture = try HTTPSProxyFixture()
        defer { fixture.stop() }
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("safarier-mieru-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let allocator = SingboxProcessManager(stateDirectory: root)
        let port = try allocator.port(for: UUID())
        let config: [String: Any] = [
            "listenIPAddress": "127.0.0.1", "loggingLevel": "ERROR", "dns": ["dualStack": "PREFER_IPv4"],
            "portBindings": [["port": port, "protocol": "TCP"]],
            "users": [["name": "test-user", "password": "test-secret", "allowLoopbackIP": true, "allowPrivateIP": true]]
        ]
        let configURL = root.appendingPathComponent("server.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: configURL.path, contents: try JSONSerialization.data(withJSONObject: config), attributes: [.posixPermissions: 0o600]))
        let server = Process()
        server.executableURL = URL(fileURLWithPath: serverPath)
        server.arguments = ["run"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "MITA_CONFIG_FILE")
        environment["MITA_CONFIG_JSON_FILE"] = configURL.path
        environment["MITA_UDS_PATH"] = root.appendingPathComponent("server.sock").path
        environment["MITA_INSECURE_UDS"] = "1"
        server.environment = environment
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        let deadline = Date().addingTimeInterval(5)
        while server.isRunning, SingboxProcessManager.isPortAvailable(port), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(server.isRunning)
        XCTAssertFalse(SingboxProcessManager.isPortAvailable(port))
        let node = SubscriptionNode(name: "Mieru", type: .mieru, server: "127.0.0.1", serverPort: port,
            username: "test-user", password: "test-secret", transport: "TCP", parameters: ["multiplexing": "MULTIPLEXING_LOW"])
        let target = URL(string: "https://localhost:\(try XCTUnwrap(fixture.ports["https"]))/trace")!
        let certificate = fixture.root.appendingPathComponent("cert.pem")
        let tester: ProxyConnectionTester.Test = { local, password in
            try await ProxyConnectionTester.check(proxy: local, password: password, target: target, certificate: certificate, timeout: 3)
        }
        let standalone = try await ProxyConnectionTester.check(node: node, using: tester)
        XCTAssertEqual(standalone.exitIP, "203.0.113.7")
        let workspace = SafarierWorkspace(root: root.appendingPathComponent("workspace"))
        let subscription = Subscription(name: "Example", url: URL(string: "https://example.com/sub")!, nodes: [node])
        try workspace.subscriptions.insert(subscription)
        let exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "127.0.0.1", port: try XCTUnwrap(fixture.ports["http"]),
            username: "test-user", upstream: .node(subscriptionID: subscription.id, name: node.name))
        let credentials = InMemoryCredentialStore()
        try credentials.setPassword("test-secret", forKey: exit.credentialKey)
        let chain = try XCTUnwrap(ProxyChainBuilder.resolve(exit, in: workspace, credentials: credentials))
        let chained = try await ProxyConnectionTester.check(chain: chain, using: tester)
        XCTAssertEqual(chained.exitIP, "203.0.113.7")
        let requests = try Data(contentsOf: fixture.root.appendingPathComponent("target-requests"))
        server.terminate()
        server.waitUntilExit()
        do {
            _ = try await ProxyConnectionTester.check(chain: chain, using: tester)
            XCTFail("Offline Mieru must not fall back to the directly reachable exit")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("target-requests")), requests)
    }

    private actor LocalPort {
        var value: Int?
        func set(_ port: Int) { value = port }
    }
}
