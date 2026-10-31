import XCTest
import WebKit
@testable import SafarierWebKit
import SafarierCore

final class DataStoreManagerTests: XCTestCase {
    private var usedPersistentIDs: [UUID] = []

    @MainActor
    func testEphemeralProfileGetsNonPersistentStore() {
        let manager = DataStoreManager()
        let profile = Profile(name: "Eph", mode: .ephemeral)

        let first = manager.dataStore(for: profile)
        let second = manager.dataStore(for: profile)

        XCTAssertFalse(first.isPersistent)
        XCTAssertFalse(first === second)
    }

    @MainActor
    func testPersistentProfileGetsStoreWithProfileID() {
        let manager = DataStoreManager()
        let profile = Profile(name: "Per", mode: .persistent)
        usedPersistentIDs.append(profile.id)

        let store = manager.dataStore(for: profile)

        XCTAssertTrue(store.isPersistent)
        XCTAssertEqual(store.identifier, profile.id)
    }

    // MARK: - 照 Safari 建

    @MainActor
    private func statistics(_ store: WKWebsiteDataStore, _ symbols: DataStoreManager.Symbols = .webKit) throws -> Bool {
        try SPIRuntimeBridge.getBool(symbols.statisticsGetter, on: store).get()
    }

    /// 临时环境照 Safari 无痕的做法建：内存存储、两项配置开关回读一致、智能防跟踪开着。
    @MainActor
    func testSafariEphemeralStoreUsesNativeNonPersistentConfiguration() throws {
        let symbols = DataStoreManager.Symbols.webKit
        guard NSClassFromString(symbols.configurationClass) != nil else { throw XCTSkip("本机 WebKit 没有数据存储配置类") }
        let manager = DataStoreManager()
        let created = manager.safariDataStore(for: Profile(name: "Eph", mode: .ephemeral))
        XCTAssertFalse(created.store.isPersistent, "临时环境绝不落盘")
        guard case .active(let text) = created.state else { return XCTFail("\(created.state)") }
        XCTAssertTrue(text.contains("Safari 无痕同款内存数据存储（快速证书校验、缓存推测校验已打开，回读一致）"), text)
        XCTAssertTrue(text.contains("智能防跟踪（ITP）开启（回读一致）"), text)
        XCTAssertTrue(try statistics(created.store))
        XCTAssertFalse(created.store === manager.safariDataStore(for: Profile(name: "Eph", mode: .ephemeral)).store, "每次新建一个")
    }

    /// 本机没有这套接口：退回公开 API 的内存存储，照样隔离，如实说明。
    @MainActor
    func testSafariEphemeralStoreFallsBackWhenNativePathIsUnavailable() {
        var symbols = DataStoreManager.Symbols.webKit
        symbols.configurationClass = "_SafarierNoSuchDataStoreConfiguration"
        symbols.statisticsGetter = "_safarierNoSuchStatistics"
        symbols.statisticsSetter = "_setSafarierNoSuchStatistics:"
        let created = DataStoreManager(symbols: symbols).safariDataStore(for: Profile(name: "Eph", mode: .ephemeral))
        XCTAssertFalse(created.store.isPersistent)
        guard case .active(let text) = created.state else { return XCTFail("\(created.state)") }
        XCTAssertTrue(text.hasPrefix("WKWebsiteDataStore.nonPersistent()，窗口关闭即销毁；Safari 无痕数据存储配置不可用，已退回公开 API"), text)
        XCTAssertTrue(text.contains("本机引擎没有智能防跟踪开关，保持默认"), text)
    }

    /// 安全底线：原生路径建出来的若是持久存储（这里换成普通 init，本机实测得到的就是持久配置），绝不使用，退回内存存储并降级。
    @MainActor
    func testSafariEphemeralStoreNeverUsesAPersistentStore() throws {
        var symbols = DataStoreManager.Symbols.webKit
        guard NSClassFromString(symbols.configurationClass) != nil else { throw XCTSkip("本机 WebKit 没有数据存储配置类") }
        symbols.nonPersistentInitializer = "init"
        let created = DataStoreManager(symbols: symbols).safariDataStore(for: Profile(name: "Eph", mode: .ephemeral))
        XCTAssertFalse(created.store.isPersistent, "退回了内存存储")
        guard case .degraded(let text) = created.state else { return XCTFail("\(created.state)") }
        XCTAssertTrue(text.contains("没有生效") && text.contains("建出来的不是内存存储"), text)
    }

    /// 持久环境照旧绑定 profile 标识，另外确认智能防跟踪开着。
    @MainActor
    func testSafariPersistentStoreKeepsIdentifierAndEnablesStatistics() throws {
        let profile = Profile(name: "Per", mode: .persistent)
        usedPersistentIDs.append(profile.id)
        let created = DataStoreManager().safariDataStore(for: profile)
        XCTAssertTrue(created.store.isPersistent)
        XCTAssertEqual(created.store.identifier, profile.id)
        guard case .active(let text) = created.state else { return XCTFail("\(created.state)") }
        XCTAssertTrue(text.hasPrefix("WKWebsiteDataStore(forIdentifier: \(profile.id.uuidString))"), text)
        if WKWebsiteDataStore.instancesRespond(to: NSSelectorFromString(DataStoreManager.Symbols.webKit.statisticsSetter)) {
            XCTAssertTrue(try statistics(created.store))
        }
    }

    /// 配置工厂：开着 Safari 专有接口才照 Safari 建；独立代理照常配置在建出来的数据存储上。
    @MainActor
    func testFactoryUsesSafariDataStoreOnlyWithSafariAPIs() throws {
        let profile = Profile(name: "Eph", mode: .ephemeral)
        let proxy = ProxySettings(name: "x", kind: .socks5, host: "127.0.0.1", port: 20001)
        var withProxy = profile
        withProxy.proxyID = proxy.id
        let safari = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(),
                                                 privacy: CompositePrivacyAdapter([PublicAPIPrivacyAdapter(), SPIPrivacyAdapter(features: .safariAPIs)]),
                                                 safariApplicationName: nil)
        let output = try safari.make(profile: withProxy, proxy: proxy, processLanguages: [])
        XCTAssertFalse(output.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(output.configuration.websiteDataStore.proxyConfigurations.count, 1, "代理配置在照 Safari 建的数据存储上照常生效")
        if NSClassFromString(DataStoreManager.Symbols.webKit.configurationClass) != nil {
            XCTAssertTrue(output.report[.dataIsolation].summary.contains("Safari 无痕同款内存数据存储"), output.report[.dataIsolation].summary)
        }

        let publicOnly = try WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: nil)
            .make(profile: profile, proxy: nil, processLanguages: [])
        XCTAssertEqual(publicOnly.report[.dataIsolation], .active("WKWebsiteDataStore.nonPersistent()，窗口关闭即销毁"), "只用公开 API 时不碰原生接口")
    }

    override func tearDown() async throws {
        let ids = usedPersistentIDs
        usedPersistentIDs = []
        let manager = await DataStoreManager()
        for id in ids {
            try? await manager.removePersistentData(for: id)
        }
        try await super.tearDown()
    }
}
