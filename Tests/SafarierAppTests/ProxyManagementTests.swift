import XCTest
import SafarierCore
import SafarierWebKit
@testable import Safarier

@MainActor
final class ProxyManagementTests: XCTestCase {
    private var root: URL!
    private var workspace: SafarierWorkspace!
    private var credentials: InMemoryCredentialStore!
    private var model: ManagerModel!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        workspace = SafarierWorkspace(root: root)
        credentials = InMemoryCredentialStore()
        model = ManagerModel(workspace: workspace, credentials: credentials)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAuthenticatedProxyIsReusableAndUsesExistingWebKitPath() throws {
        let proxy = ProxySettings(name: "Shared", kind: .httpConnect, host: "127.0.0.1", port: 8080, username: "user")
        try model.saveProxy(proxy, password: "secret-password", isNew: true)
        XCTAssertEqual(try credentials.password(forKey: proxy.credentialKey), "secret-password")
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("proxies.json"), encoding: .utf8).contains("secret-password"))
        for name in ["One", "Two"] {
            let profile = Profile(name: name, mode: .ephemeral, proxyID: proxy.id)
            try model.save(profile, isNew: true)
            let output = try WebViewConfigurationFactory(credentials: credentials).make(profile: profile, proxy: proxy)
            XCTAssertEqual(output.configuration.websiteDataStore.proxyConfigurations.count, 1)
            XCTAssertNil(profile.customOutboundJSON)
        }
        XCTAssertEqual(model.profiles(using: proxy).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.singboxDirectory.path))
        var edited = proxy
        edited.kind = .socks5
        edited.host = "proxy.example"
        try model.saveProxy(edited, password: nil, isNew: false)
        XCTAssertEqual(try workspace.proxies.record(id: proxy.id), edited)
        XCTAssertEqual(try credentials.password(forKey: proxy.credentialKey), "secret-password")
        XCTAssertEqual(try workspace.profiles.all().map(\.proxyID), [proxy.id, proxy.id])
    }

    func testPasswordReplacementAuthenticationRemovalAndDelete() throws {
        var proxy = ProxySettings(name: "Auth", kind: .socks5, host: "127.0.0.1", port: 1080, username: "user")
        XCTAssertThrowsError(try model.saveProxy(proxy, password: nil, isNew: true))
        XCTAssertTrue(try workspace.proxies.all().isEmpty)
        try model.saveProxy(proxy, password: "old", isNew: true)
        try model.saveProxy(proxy, password: "new", isNew: false)
        XCTAssertEqual(try credentials.password(forKey: proxy.credentialKey), "new")
        proxy.username = nil
        try model.saveProxy(proxy, password: nil, isNew: false)
        XCTAssertNil(try credentials.password(forKey: proxy.credentialKey))
        proxy.username = "user"
        try model.saveProxy(proxy, password: "again", isNew: false)
        try model.deleteProxy(proxy)
        XCTAssertTrue(model.proxies.isEmpty)
        XCTAssertNil(try credentials.password(forKey: proxy.credentialKey))
        XCTAssertNil(model.selection)
    }

    func testDeleteChecksLatestProfileReferencesAndKeepsCredentials() throws {
        let proxy = ProxySettings(name: "Used", kind: .socks5, host: "127.0.0.1", port: 1080, username: "user")
        try model.saveProxy(proxy, password: "secret", isNew: true)
        // 模拟 CLI 在管理器刷新前添加引用。
        let profile = Profile(name: "CLI profile", mode: .ephemeral, proxyID: proxy.id)
        try workspace.profiles.insert(profile)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertThrowsError(try model.deleteProxy(proxy))
        XCTAssertNotNil(try workspace.proxies.record(id: proxy.id))
        XCTAssertEqual(try credentials.password(forKey: proxy.credentialKey), "secret")
    }

    func testMetadataWriteFailureRestoresOriginalPassword() throws {
        let proxy = ProxySettings(name: "Before", kind: .socks5, host: "127.0.0.1", port: 1080, username: "user")
        try model.saveProxy(proxy, password: "old", isNew: true)
        let lock = root.appendingPathComponent("proxies.json.lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        var edited = proxy
        edited.name = "After"
        XCTAssertThrowsError(try model.saveProxy(edited, password: "new", isNew: false))
        XCTAssertEqual(try workspace.proxies.record(id: proxy.id), proxy)
        XCTAssertEqual(try credentials.password(forKey: proxy.credentialKey), "old")
    }

    func testCredentialFailureDoesNotSaveMetadata() throws {
        struct UnavailableCredentials: CredentialStore {
            func password(forKey key: String) throws -> String? { nil }
            func setPassword(_ password: String, forKey key: String) throws { throw CredentialStoreError.keychain(-1) }
            func removePassword(forKey key: String) throws {}
        }
        let model = ManagerModel(workspace: workspace, credentials: UnavailableCredentials())
        let proxy = ProxySettings(name: "Auth", kind: .socks5, host: "127.0.0.1", port: 1080, username: "user")
        XCTAssertThrowsError(try model.saveProxy(proxy, password: "secret", isNew: true))
        XCTAssertTrue(try workspace.proxies.all().isEmpty)
    }

    func testLegacyCustomOutboundIsPreservedWhenChoosingAnotherProxy() throws {
        let json = #"{"type":"http","server":"proxy.example","server_port":8080,"username":"user","password":"secret"}"#
        let old = Profile(name: "Previous manual config", mode: .ephemeral, customOutboundJSON: json)
        try workspace.profiles.insert(old)
        model.reload()
        XCTAssertEqual(model.profile(old.id)?.customOutboundJSON, json)
        XCTAssertEqual(model.duplicate(old)?.customOutboundJSON, json)
        let proxy = ProxySettings(name: "Shared", kind: .httpConnect, host: "proxy.example", port: 8080)
        try model.saveProxy(proxy, password: nil, isNew: true)
        var switched = old
        switched.customOutboundJSON = nil
        switched.proxyID = proxy.id
        try model.save(switched, isNew: false)
        XCTAssertEqual(try workspace.profiles.record(id: old.id)?.proxyID, proxy.id)
        XCTAssertNil(try workspace.profiles.record(id: old.id)?.customOutboundJSON)
    }
}
