import XCTest
import WebKit
import SafarierCore
import SafarierObjCSupport
@testable import SafarierWebKit

/// SPIPrivacyAdapter 的 fontlist 分支：版本门槛、语言、计划合理性、桥返回值 → 能力状态，以及桥收到的进程池。
/// 全部用注入的版本号 / 规划器 / 桥，不碰真实的 引擎上下文SetFontAllowList。
@MainActor
final class FontAllowlistAdapterTests: XCTestCase {
    private let verifiedVersion = "20621.3.11.11.3"
    private let english = Profile(name: "en", mode: .ephemeral, languages: ["en-US", "en"])

    /// 记录桥被调用的情况。
    private final class BridgeRecorder {
        var calls: [(pool: AnyObject?, names: [String])] = []
        var status: SFRCallStatus = .OK
        var detail: String? = "fake"

        func bridge() -> @MainActor (AnyObject?, [String]) -> (SFRCallStatus, String?) {
            { [self] pool, names in
                calls.append((pool, names))
                return (status, detail)
            }
        }
    }

    /// 线程安全地记录规划器收到的语言（规划器闭包是 @Sendable）。
    private final class PlannerRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        let plan: FontAllowlistPlan

        init(plan: FontAllowlistPlan) { self.plan = plan }

        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }

        func planner() -> @Sendable ([String]) -> FontAllowlistPlan {
            { [self] languages in
                lock.lock(); _calls.append(languages); lock.unlock()
                return plan
            }
        }
    }

    private nonisolated static func plan(nameCount: Int) -> FontAllowlistPlan {
        FontAllowlistPlan(
            names: (0..<nameCount).map { String(format: "Font%04d", $0) },
            excludedFamilies: ["PingFang SC", "PingFang TC"],
            excludedFontCount: 12,
            sharedNamesDropped: 0
        )
    }

    private func run(
        features: SPIFeatures = .fontAllowlist,
        version: String? = "20621.3.11.11.3",
        profile: Profile? = nil,
        planner: PlannerRecorder = PlannerRecorder(plan: plan(nameCount: 600)),
        bridge: BridgeRecorder,
        configuration: WKWebViewConfiguration? = nil,
        diagnostics: SPIDiagnostics = SPIDiagnostics()
    ) -> CapabilityState {
        let configuration = configuration ?? WKWebViewConfiguration()
        var report = PrivacyCapabilityReport()
        SPIPrivacyAdapter(
            features: features,
            diagnostics: diagnostics,
            webKitVersion: version,
            fontAllowlistPlanner: planner.planner(),
            fontAllowlistBridge: bridge.bridge()
        ).apply(to: configuration, for: profile ?? english, report: &report)
        return report[.fontAllowlist]
    }

    func testNotRequestedWithoutFeature() {
        let bridge = BridgeRecorder()
        let planner = PlannerRecorder(plan: Self.plan(nameCount: 600))
        XCTAssertEqual(run(features: [], planner: planner, bridge: bridge), .notRequested)
        XCTAssertEqual(run(features: .all, version: nil, planner: planner, bridge: BridgeRecorder()).name, "unavailable", "all 含 fontlist")
        XCTAssertEqual(run(features: .defaultFeatures, version: nil, planner: planner, bridge: BridgeRecorder()).name, "unavailable", "默认开启 fontlist")
        XCTAssertTrue(bridge.calls.isEmpty)
        XCTAssertTrue(planner.calls.isEmpty)
    }

    func testUnverifiedWebKitIsUnavailableAndNeverCallsBridge() {
        let bridge = BridgeRecorder()
        let planner = PlannerRecorder(plan: Self.plan(nameCount: 600))
        let diagnostics = SPIDiagnostics()
        let state = run(version: "20000.1", planner: planner, bridge: bridge, diagnostics: diagnostics)
        guard case .unavailable(let text) = state else { return XCTFail("\(state)") }
        XCTAssertTrue(text.contains("20000.1"), text)
        XCTAssertTrue(bridge.calls.isEmpty)
        XCTAssertTrue(planner.calls.isEmpty, "版本不对时不应遍历字体")
        XCTAssertTrue(diagnostics.entries.contains { $0.hasPrefix("fontlist：unavailable") }, "\(diagnostics.entries)")

        // 不在已验证前缀里的版本（例如 macOS 13 的 18615）不调用。
        XCTAssertEqual(run(version: "18615.1.1", bridge: bridge).name, "unavailable")
        XCTAssertEqual(run(version: nil, bridge: bridge).name, "unavailable")
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    /// 已验证前缀覆盖 macOS 14 / 15 / 26 / 27 和下一代的系统 WebKit。
    func testVerifiedPrefixesCoverModernMacOSWebKit() {
        XCTAssertEqual(SPIPrivacyAdapter.Symbols.webKit.fontAllowlistVerifiedWebKitPrefixes, ["196", "206", "216", "226", "236"])
        for version in ["19618.3.11.11.5", "20620.2.4.11.6", "20621.3.11.11.3", "21622.1.22.11.15", "22625.1.29.11.27", "23626.1.1"] {
            let bridge = BridgeRecorder()
            XCTAssertEqual(run(version: version, bridge: bridge).name, "active", version)
            XCTAssertEqual(bridge.calls.count, 1, version)
        }
    }

    func testMacOS27EngineReachesInjectedBridge() {
        for version in ["22625.1.29.11.27", "22625.2.8.18.4"] {
            let bridge = BridgeRecorder()
            XCTAssertEqual(run(version: version, bridge: bridge).name, "active")
            XCTAssertEqual(bridge.calls.count, 1, version)
        }
    }

    /// 跟随系统时只采用进程首选语言，仍经过规划器和字体桥接。
    func testEmptyProfileLanguagesUsesFirstProcessPreferredLanguageAndCallsBridge() {
        let bridge = BridgeRecorder()
        let planner = PlannerRecorder(plan: Self.plan(nameCount: 600))
        let followSystem = Profile(name: "sys", mode: .ephemeral, languages: [])
        let expectedLanguages = Locale.preferredLanguages.first.map { [$0] } ?? []
        XCTAssertEqual(run(version: verifiedVersion, profile: followSystem, planner: planner, bridge: bridge).name, "active")
        XCTAssertEqual(planner.calls, [expectedLanguages])
        XCTAssertEqual(bridge.calls.count, 1)
        XCTAssertEqual(bridge.calls.first?.names, planner.plan.names)
    }

    func testEmptyProfileLanguagesStillChecksEngineVersionBeforePlanning() {
        let bridge = BridgeRecorder()
        let planner = PlannerRecorder(plan: Self.plan(nameCount: 600))
        let followSystem = Profile(name: "sys", mode: .ephemeral, languages: [])
        XCTAssertEqual(run(version: "18615.1.1", profile: followSystem, planner: planner, bridge: bridge).name, "unavailable")
        XCTAssertTrue(bridge.calls.isEmpty)
        XCTAssertTrue(planner.calls.isEmpty)
    }

    func testNoOpPlanIsActiveWithoutBridgeCall() {
        let bridge = BridgeRecorder()
        let planner = PlannerRecorder(plan: FontAllowlistPlan(names: [], excludedFamilies: [], excludedFontCount: 0, sharedNamesDropped: 0))
        let zh = Profile(name: "zh", mode: .ephemeral, languages: ["zh-CN", "zh"])
        XCTAssertEqual(run(profile: zh, planner: planner, bridge: bridge).name, "active")
        XCTAssertEqual(planner.calls, [["zh-CN", "zh"]], "规划器应收到 Profile 的语言")
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testImplausiblySmallPlanIsDegradedWithoutBridgeCall() {
        let bridge = BridgeRecorder()
        let state = run(planner: PlannerRecorder(plan: Self.plan(nameCount: 10)), bridge: bridge)
        guard case .degraded(let text) = state else { return XCTFail("\(state)") }
        XCTAssertTrue(text.contains("10"), text)
        XCTAssertTrue(bridge.calls.isEmpty)
        // 门槛是 500：499 仍然不调用。
        XCTAssertEqual(run(planner: PlannerRecorder(plan: Self.plan(nameCount: 499)), bridge: bridge).name, "degraded")
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testMissingSymbolFromBridgeIsUnavailable() {
        let bridge = BridgeRecorder()
        bridge.status = .missingSymbol
        bridge.detail = "fontAllowlist 缺少引擎导出"
        let state = run(bridge: bridge)
        guard case .unavailable(let text) = state else { return XCTFail("\(state)") }
        XCTAssertTrue(text.contains("fontAllowlist"), text)
        XCTAssertEqual(bridge.calls.count, 1)
    }

    func testSignatureMismatchFromBridgeIsDegraded() {
        let bridge = BridgeRecorder()
        bridge.status = .signatureMismatch
        bridge.detail = "processPool 引擎类型不符"
        let state = run(bridge: bridge)
        guard case .degraded(let text) = state else { return XCTFail("\(state)") }
        XCTAssertTrue(text.contains("引擎类型"), text)
        XCTAssertEqual(bridge.calls.count, 1)
    }

    /// 白名单是设在进程池上的：测试要直接构造、比较 进程池对象（macOS 12 起标为弃用，但 WebKit 仍按池区分）。
    @available(macOS, deprecated: 12.0)
    func testOKPassesPlanNamesAndCurrentProcessPool() throws {
        let bridge = BridgeRecorder()
        let plan = Self.plan(nameCount: 600)
        let configuration = WKWebViewConfiguration()
        let customPool = try SPIRuntimeBridge.newInstance(className: SPIPrivacyAdapter.Symbols.webKit.processPoolClass).get()
        try SPIRuntimeBridge.setObject(customPool, SPIPrivacyAdapter.Symbols.webKit.processPoolSetter, on: configuration).get()
        let state = run(planner: PlannerRecorder(plan: plan), bridge: bridge, configuration: configuration)

        guard case .active(let text) = state else { return XCTFail("\(state)") }
        XCTAssertTrue(text.contains("600"), text)
        XCTAssertTrue(text.contains("PingFang SC"), text)
        XCTAssertEqual(bridge.calls.count, 1)
        let call = try XCTUnwrap(bridge.calls.first)
        XCTAssertEqual(call.names, plan.names)
        let current = try XCTUnwrap(try SPIRuntimeBridge.getObject(SFRSymbolDecoder.decode([0x2A, 0x28, 0x35, 0x39, 0x3F, 0x29, 0x29, 0x0A, 0x35, 0x35, 0x36]), on: configuration).get())
        XCTAssertTrue(call.pool === current, "桥应收到 configuration 当前的 processPool")
        XCTAssertTrue(call.pool === customPool)
    }

    /// tz 会给 configuration 换上新进程池；白名单必须设在换过之后的那个上面。
    @available(macOS, deprecated: 12.0)
    func testAllowlistGoesToPoolInstalledByTimeZone() throws {
        let hasTimeZone = NSClassFromString(SPIPrivacyAdapter.Symbols.webKit.processPoolConfigurationClass) != nil
        try XCTSkipUnless(hasTimeZone, "本机引擎没有时区配置能力")
        let bridge = BridgeRecorder()
        let configuration = WKWebViewConfiguration()
        let poolBefore = try SPIRuntimeBridge.getObject(SPIPrivacyAdapter.Symbols.webKit.processPoolGetter, on: configuration).get()
        let tokyo = Profile(name: "t", mode: .ephemeral, languages: ["en-US"], timeZoneIdentifier: "Asia/Tokyo")
        XCTAssertEqual(run(features: [.engineTimeZone, .fontAllowlist], profile: tokyo, bridge: bridge, configuration: configuration).name, "active")
        let call = try XCTUnwrap(bridge.calls.first)
        XCTAssertFalse(call.pool === poolBefore)
        let current = try SPIRuntimeBridge.getObject(SPIPrivacyAdapter.Symbols.webKit.processPoolGetter, on: configuration).get()
        XCTAssertTrue(call.pool === current)
    }
}
