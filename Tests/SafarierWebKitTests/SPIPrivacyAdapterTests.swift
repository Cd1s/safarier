import XCTest
import WebKit
import SafarierCore
@testable import SafarierWebKit

@MainActor
final class SPIPrivacyAdapterTests: XCTestCase {
    private let tokyo = Profile(name: "t", mode: .ephemeral, timeZoneIdentifier: "Asia/Tokyo")

    private func adapter(
        _ features: SPIFeatures,
        symbols: SPIPrivacyAdapter.Symbols = mockSymbols,
        diagnostics: SPIDiagnostics = SPIDiagnostics(),
        webpage: NSObject = EmptyObject(),
        preferences: NSObject = EmptyObject(),
        install: @escaping @MainActor (WKWebViewConfiguration, NSObject) -> Bool = { _, _ in XCTFail("不应安装进程池"); return false }
    ) -> SPIPrivacyAdapter {
        SPIPrivacyAdapter(
            features: features,
            symbols: symbols,
            diagnostics: diagnostics,
            webpagePreferences: { _ in webpage },
            commitWebpagePreferences: { _, _ in },
            preferences: { _ in preferences },
            installProcessPool: install
        )
    }

    private func apply(_ adapter: SPIPrivacyAdapter, profile: Profile? = nil) -> PrivacyCapabilityReport {
        var report = PrivacyCapabilityReport()
        report.set(.unavailable("工厂写下的结论"), for: .timeZone)
        adapter.apply(to: WKWebViewConfiguration(), for: profile ?? tokyo, report: &report)
        return report
    }

    // MARK: - 不开启

    func testNothingRequestedTouchesNothing() {
        let webpage = FakePolicyPreferences()
        let preferences = FakePeerConnectionPreferences()
        let report = apply(adapter([], webpage: webpage, preferences: preferences))

        XCTAssertEqual(report[.advancedPrivacyProtections], .notRequested)
        XCTAssertEqual(report[.webRTCDisabled], .notRequested)
        XCTAssertEqual(report[.timeZone], .unavailable("工厂写下的结论"))
        XCTAssertTrue(webpage.writes.isEmpty)
        XCTAssertEqual(preferences.writeCount, 0)
    }

    // MARK: - afp

    func testFingerprintingKeepsExistingBitsAndReadsBack() {
        let diagnostics = SPIDiagnostics()
        let webpage = FakePolicyPreferences(stored: 0x2)
        let report = apply(adapter(.fingerprintingProtections, diagnostics: diagnostics, webpage: webpage))

        XCTAssertEqual(webpage.stored, 0x2 | SPIPrivacyAdapter.fingerprintingPolicyMask)
        XCTAssertEqual(SPIPrivacyAdapter.fingerprintingPolicyMask, 0x1C1, "和 SafariSharedUI 无痕模式一样：0x1 | 0x40 | 0x80 | 0x100")
        guard case .active(let text) = report[.advancedPrivacyProtections] else { return XCTFail("\(report[.advancedPrivacyProtections])") }
        XCTAssertTrue(text.contains("0x2 → 0x1c3"), text)
        XCTAssertTrue(text.contains("只核对了位掩码"), "测试对象没有总开关读法：兼容跳过，不报错。\(text)")
        XCTAssertTrue(diagnostics.entries.contains { $0.hasPrefix("afp：") })
    }

    /// 引擎的总开关要四位齐全：少了 0x1（以前只写 0x1c0）时总开关是 NO。
    func testFingerprintingTurnsOnEngineSwitch() {
        let webpage = EngineLikePolicyPreferences()
        let report = apply(adapter(.fingerprintingProtections, webpage: webpage))
        XCTAssertEqual(webpage.stored, 0x1C1)
        XCTAssertTrue(webpage.policyEnabled)
        guard case .active(let text) = report[.advancedPrivacyProtections] else { return XCTFail("\(report[.advancedPrivacyProtections])") }
        XCTAssertTrue(text.contains("0x0 → 0x1c1"), text)
        XCTAssertTrue(text.contains("引擎总开关回读 YES"), text)

        let withoutBaseline = EngineLikePolicyPreferences(stored: 0x1C0)
        XCTAssertFalse(withoutBaseline.policyEnabled, "只有三个反指纹位时总开关是 NO")
    }

    func testEngineSwitchReadingNoIsDegradedEvenWhenBitsReadBack() {
        let diagnostics = SPIDiagnostics()
        let webpage = SwitchOffPolicyPreferences()
        let report = apply(adapter(.fingerprintingProtections, diagnostics: diagnostics, webpage: webpage))
        XCTAssertEqual(webpage.stored & SPIPrivacyAdapter.fingerprintingPolicyMask, SPIPrivacyAdapter.fingerprintingPolicyMask, "位掩码回读看起来是齐的")
        guard case .degraded(let text) = report[.advancedPrivacyProtections] else { return XCTFail("\(report[.advancedPrivacyProtections])") }
        XCTAssertTrue(text.contains("引擎总开关回读为 NO"), text)
        XCTAssertTrue(diagnostics.entries.contains { $0.hasPrefix("afp：") && $0.contains("回读为 NO") })
    }

    func testEngineSwitchExceptionIsDegradedWithoutCrash() {
        let report = apply(adapter(.fingerprintingProtections, webpage: ThrowingSwitchPolicyPreferences()))
        guard case .degraded(let text) = report[.advancedPrivacyProtections] else { return XCTFail("\(report[.advancedPrivacyProtections])") }
        XCTAssertTrue(text.contains("引擎总开关回读失败"), text)
        XCTAssertTrue(text.contains("NSInternalInconsistencyException"), text)
    }

    /// 编码的总开关读法和本机 WebKit 对得上：和位掩码读法同一前缀、BOOL 返回、无参数。不在源码里写明文。
    func testEngineSwitchSymbolMatchesThisWebKit() throws {
        let symbols = SPIPrivacyAdapter.Symbols.webKit
        XCTAssertEqual(symbols.networkPolicyEnabledGetter, String(symbols.networkPolicyGetter.dropLast("Policy".count)) + "Enabled")
        XCTAssertTrue(symbols.networkPolicyEnabledGetter.hasPrefix("_"))
        guard let method = class_getInstanceMethod(WKWebpagePreferences.self, NSSelectorFromString(symbols.networkPolicyEnabledGetter)) else {
            throw XCTSkip("本机 WebKit 没有总开关读法，适配器按位掩码报告")
        }
        XCTAssertEqual(String(cString: try XCTUnwrap(method_getTypeEncoding(method))), "B16@0:8")
    }

    func testFingerprintingReadBackMismatchIsDegraded() {
        let webpage = FakePolicyPreferences()
        webpage.ignoreWrites = true
        guard case .degraded(let text) = apply(adapter(.fingerprintingProtections, webpage: webpage))[.advancedPrivacyProtections] else {
            return XCTFail("回读不一致应当降级")
        }
        XCTAssertTrue(text.contains("回读"), text)
    }

    func testFingerprintingExceptionIsDegradedWithoutCrash() {
        let diagnostics = SPIDiagnostics()
        let report = apply(adapter(.fingerprintingProtections, diagnostics: diagnostics, webpage: ThrowingPolicyPreferences()))
        guard case .degraded(let text) = report[.advancedPrivacyProtections] else { return XCTFail("\(report[.advancedPrivacyProtections])") }
        XCTAssertTrue(text.contains("NSInternalInconsistencyException"), text)
        XCTAssertTrue(diagnostics.entries.contains { $0.contains("已降级") })
    }

    // MARK: - webrtc

    func testPeerConnectionDisabledAndReadBack() {
        let preferences = FakePeerConnectionPreferences()
        guard case .active = apply(adapter(.disableWebRTC, preferences: preferences))[.webRTCDisabled] else { return XCTFail() }
        XCTAssertFalse(preferences.enabled)
    }

    func testPeerConnectionIgnoredWriteIsDegraded() {
        let preferences = FakePeerConnectionPreferences()
        preferences.ignoreWrites = true
        guard case .degraded = apply(adapter(.disableWebRTC, preferences: preferences))[.webRTCDisabled] else { return XCTFail() }
    }

    func testWrongSignatureIsUnavailableAndNeverCalled() {
        let preferences = WrongSignaturePeerConnectionPreferences()
        guard case .unavailable(let text) = apply(adapter(.disableWebRTC, preferences: preferences))[.webRTCDisabled] else {
            return XCTFail("签名不符应当报告 unavailable")
        }
        XCTAssertFalse(preferences.called)
        XCTAssertTrue(text.contains("类型"), text)
    }

    func testMissingSymbolsAreUnavailable() {
        let report = apply(adapter([.fingerprintingProtections, .disableWebRTC]))
        guard case .unavailable = report[.advancedPrivacyProtections] else { return XCTFail() }
        guard case .unavailable = report[.webRTCDisabled] else { return XCTFail() }
    }

    // MARK: - tz

    private var fakePoolSymbols: SPIPrivacyAdapter.Symbols {
        var symbols = mockSymbols
        symbols.processPoolConfigurationClass = "SafarierTestPoolConfiguration"
        symbols.processPoolClass = "SafarierTestPool"
        return symbols
    }

    func testTimeZoneOverrideInstallsPoolWithConfiguration() {
        var installed: NSObject?
        let report = apply(adapter(.engineTimeZone, symbols: fakePoolSymbols, install: { _, pool in
            installed = pool
            return true
        }))
        guard case .active(let text) = report[.timeZone] else { return XCTFail("\(report[.timeZone])") }
        XCTAssertTrue(text.contains("Asia/Tokyo"), text)
        XCTAssertTrue(text.contains("进程池配置回读一致"), text)
        let configuration = (installed as? FakePool)?.storedConfiguration as? FakePoolConfiguration
        XCTAssertEqual(configuration?.engineTimeZone, "Asia/Tokyo")
    }

    func testTimeZoneMissingClassIsUnavailableAndPoolUntouched() {
        var symbols = fakePoolSymbols
        symbols.processPoolConfigurationClass = "SafarierNoSuchClass"
        guard case .unavailable = apply(adapter(.engineTimeZone, symbols: symbols))[.timeZone] else { return XCTFail() }
    }

    func testTimeZoneSetterExceptionIsDegraded() {
        var symbols = fakePoolSymbols
        symbols.processPoolConfigurationClass = "SafarierTestThrowingPoolConfiguration"
        guard case .degraded(let text) = apply(adapter(.engineTimeZone, symbols: symbols))[.timeZone] else { return XCTFail() }
        XCTAssertTrue(text.contains("NSInvalidArgumentException"), text)
    }

    func testTimeZonePoolThatCannotBeInstalledIsDegraded() {
        guard case .degraded = apply(adapter(.engineTimeZone, symbols: fakePoolSymbols, install: { _, _ in false }))[.timeZone] else {
            return XCTFail()
        }
    }

    func testTimeZoneRequestedWithoutProfileZoneKeepsFactoryResult() {
        let diagnostics = SPIDiagnostics()
        let report = apply(adapter(.engineTimeZone, symbols: fakePoolSymbols, diagnostics: diagnostics), profile: Profile(name: "n", mode: .ephemeral))
        XCTAssertEqual(report[.timeZone], .unavailable("工厂写下的结论"))
        XCTAssertTrue(diagnostics.entries.contains { $0.contains("没有设置时区") })
    }

    // MARK: - safari

    func testSafariAPIsEnabledAndReadBack() {
        let preferences = FakeSafariAPIPreferences()
        let report = apply(adapter(.safariAPIs, preferences: preferences))

        XCTAssertTrue(preferences.applePay && preferences.push && preferences.mediaDevices)
        XCTAssertFalse(preferences.applePayDisclosure)
        XCTAssertFalse(preferences.userInstalledFonts)
        guard case .active(let text) = report[.safariAPIs] else { return XCTFail("\(report[.safariAPIs])") }
        XCTAssertTrue(text.contains("ApplePaySession") && text.contains("PushManager") && text.contains("navigator.mediaDevices"), text)
        XCTAssertTrue(text.contains("关闭用户安装字体"), text)
        XCTAssertTrue(text.contains("本机引擎没有：退格键不后退、服务控件、截断文字悬停提示、电话号码识别、积极保留图块，保持默认"), "没有行为默认值接口的对象：跳过，不报错。\(text)")
    }

    /// Safari 另设的 5 个 WKPreferences 行为默认值：有读写接口就写成 Safari 的值并回读。
    func testSafariBehaviorDefaultsAlignAndReadBack() {
        let preferences = FakeSafariBehaviorPreferences()
        let report = apply(adapter(.safariAPIs, preferences: preferences))
        XCTAssertEqual(preferences.behaviors, ["backspace": false, "services": true, "tooltip": true, "telephone": true, "tiles": true])
        guard case .active(let text) = report[.safariAPIs] else { return XCTFail("\(report[.safariAPIs])") }
        XCTAssertTrue(text.contains("Safari 行为默认值：退格键不后退、服务控件、截断文字悬停提示、电话号码识别、积极保留图块"), text)
        XCTAssertFalse(text.contains("本机引擎没有"), text)
    }

    func testSafariBehaviorIgnoredWriteIsDegraded() {
        let preferences = FakeSafariBehaviorPreferences()
        preferences.ignoreBehaviorWrites = true
        guard case .degraded(let text) = apply(adapter(.safariAPIs, preferences: preferences))[.safariAPIs] else {
            return XCTFail("回读不一致应当降级")
        }
        XCTAssertTrue(text.contains("退格键不后退 写入 false 后回读为 true"), text)
    }

    // MARK: - 单次导航

    /// 4 参数导航决策回调交来的 preferences：缺位就补上并回读，不记诊断（每次导航都走）。
    func testNavigationPreferencesGetMaskWithoutDiagnostics() {
        let diagnostics = SPIDiagnostics()
        let navigation = EngineLikePolicyPreferences(stored: 0x2)
        let state = adapter(.fingerprintingProtections, diagnostics: diagnostics).navigationPreferencesState(navigation)
        XCTAssertEqual(navigation.stored, 0x1C3)
        XCTAssertTrue(navigation.policyEnabled)
        XCTAssertEqual(state.name, "active", state.summary)
        XCTAssertTrue(diagnostics.entries.isEmpty, "\(diagnostics.entries)")
    }

    func testNavigationPreferencesAlreadyAlignedAreNotRewritten() {
        let navigation = FakePolicyPreferences(stored: 0x1C1)
        let state = adapter(.fingerprintingProtections).navigationPreferencesState(navigation)
        XCTAssertEqual(state.name, "active")
        XCTAssertTrue(navigation.writes.isEmpty, "已经齐了就不写")
    }

    func testNavigationPreferencesFailureIsRecordedOnce() {
        let diagnostics = SPIDiagnostics()
        let navigation = FakePolicyPreferences()
        navigation.ignoreWrites = true
        let spi = adapter(.fingerprintingProtections, diagnostics: diagnostics)
        XCTAssertEqual(spi.navigationPreferencesState(navigation).name, "degraded")
        XCTAssertEqual(spi.navigationPreferencesState(navigation).name, "degraded")
        XCTAssertEqual(diagnostics.entries.count, 1, "同样的失败只记一条：\(diagnostics.entries)")
        XCTAssertTrue(diagnostics.entries[0].hasPrefix("afp.navigation："), diagnostics.entries[0])
    }

    func testNavigationPreferencesUntouchedWithoutFingerprintingProtections() {
        let navigation = FakePolicyPreferences()
        XCTAssertEqual(adapter([.safariAPIs, .disableWebRTC]).navigationPreferencesState(navigation), .notRequested)
        XCTAssertTrue(navigation.writes.isEmpty)
    }

    /// 真实 WKWebpagePreferences 经配置工厂交出来的入口（Runner 的 4 参数导航回调用的就是它）。
    func testFactoryNavigationEntryAlignsRealWebpagePreferences() throws {
        let symbols = SPIPrivacyAdapter.Symbols.webKit
        guard WKWebpagePreferences.instancesRespond(to: NSSelectorFromString(symbols.networkPolicySetter)) else {
            throw XCTSkip("本机 WebKit 没有高级隐私保护位接口")
        }
        let privacy = CompositePrivacyAdapter([PublicAPIPrivacyAdapter(), SPIPrivacyAdapter(features: .fingerprintingProtections)])
        let output = try WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), privacy: privacy, safariApplicationName: nil)
            .make(profile: Profile(name: "n", mode: .ephemeral), proxy: nil, processLanguages: [])
        let navigation = WKWebpagePreferences()
        XCTAssertEqual(try SPIRuntimeBridge.getUInt(symbols.networkPolicyGetter, on: navigation).get(), 0)
        output.prepareNavigationPreferences(navigation)
        XCTAssertEqual(try SPIRuntimeBridge.getUInt(symbols.networkPolicyGetter, on: navigation).get() & 0x1C1, 0x1C1)
        if WKWebpagePreferences.instancesRespond(to: NSSelectorFromString(symbols.networkPolicyEnabledGetter)) {
            XCTAssertTrue(try SPIRuntimeBridge.getBool(symbols.networkPolicyEnabledGetter, on: navigation).get())
        }

        // 只用公开 API 的适配器不碰单次导航。
        let publicOnly = try WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: nil)
            .make(profile: Profile(name: "p", mode: .ephemeral), proxy: nil, processLanguages: [])
        let untouched = WKWebpagePreferences()
        publicOnly.prepareNavigationPreferences(untouched)
        XCTAssertEqual(try SPIRuntimeBridge.getUInt(symbols.networkPolicyGetter, on: untouched).get(), 0)
    }

    /// 照 Safari 建网站数据存储跟着 Safari 专有接口这一项开关走；只用公开 API 时不碰。
    func testSafariDataStoreDefaultsFollowSafariAPIsFeature() {
        XCTAssertTrue(SPIPrivacyAdapter(features: .safariAPIs).appliesSafariDataStoreDefaults)
        XCTAssertTrue(SPIPrivacyAdapter(features: .defaultFeatures).appliesSafariDataStoreDefaults)
        XCTAssertFalse(SPIPrivacyAdapter(features: [.fingerprintingProtections, .engineTimeZone]).appliesSafariDataStoreDefaults)
        XCTAssertFalse(PublicAPIPrivacyAdapter().appliesSafariDataStoreDefaults)
        XCTAssertTrue(CompositePrivacyAdapter([PublicAPIPrivacyAdapter(), SPIPrivacyAdapter(features: .safariAPIs)]).appliesSafariDataStoreDefaults)
        XCTAssertFalse(CompositePrivacyAdapter([PublicAPIPrivacyAdapter(), SPIPrivacyAdapter(features: [])]).appliesSafariDataStoreDefaults)
    }

    func testSafariDisclosureOptOutLeavesSystemValueUntouched() {
        let preferences = FakeSafariAPIPreferences()
        var symbols = mockSymbols
        // 关闭开关后不能访问披露接口，即使旧系统没有它也不应降级。
        symbols.applePayDisclosureGetter = "safarierMissingDisclosure"
        symbols.applePayDisclosureSetter = "safarierMissingDisclosure:"
        let profile = Profile(name: "Opt out", mode: .persistent, hideApplePayCardStatus: false)
        let state = apply(adapter(.safariAPIs, symbols: symbols, preferences: preferences), profile: profile)[.safariAPIs]
        XCTAssertEqual(state.name, "active")
        XCTAssertTrue(preferences.applePayDisclosure)
        XCTAssertTrue(state.summary.contains("保留系统默认"))
    }

    func testSafariDisclosureDoesNotApplyWithoutSafariAPIs() {
        let preferences = FakeSafariAPIPreferences()
        _ = apply(adapter([], preferences: preferences))
        XCTAssertTrue(preferences.applePayDisclosure)
    }

    func testSafariDisclosureIgnoredWriteIsDegraded() {
        let preferences = FakeSafariAPIPreferences()
        preferences.ignoreDisclosureWrites = true
        let state = apply(adapter(.safariAPIs, preferences: preferences))[.safariAPIs]
        XCTAssertEqual(state.name, "degraded")
        XCTAssertTrue(state.summary.contains("银行卡状态披露"))
    }

    func testSafariDisclosureMissingIsUnavailable() {
        var symbols = mockSymbols
        symbols.applePayDisclosureSetter = "safarierMissingDisclosure:"
        let state = apply(adapter(.safariAPIs, symbols: symbols, preferences: FakeSafariAPIPreferences()))[.safariAPIs]
        XCTAssertEqual(state.name, "unavailable")
    }

    func testSafariAPIsIgnoredWriteIsDegraded() {
        let preferences = FakeSafariAPIPreferences()
        preferences.ignoreWrites = true
        XCTAssertEqual(apply(adapter(.safariAPIs, preferences: preferences))[.safariAPIs].name, "degraded")
    }

    func testSafariAPIsMissingIsUnavailable() {
        XCTAssertEqual(apply(adapter(.safariAPIs))[.safariAPIs].name, "unavailable")
        XCTAssertEqual(apply(adapter([]))[.safariAPIs], .notRequested)
    }

    private var paritySymbols: SPIPrivacyAdapter.Symbols {
        var symbols = mockSymbols
        symbols.featuresGetter = "safarierParityFeatures"
        symbols.featureKeyGetter = "safarierParityKey"
        symbols.featureGetter = "safarierParityEnabled:"
        symbols.featureSetter = "setSafarierParityEnabled:feature:"
        symbols.legacyEventFeatureKeys = ["legacy"]
        symbols.authenticationFeatureKeys = ["auth", "authServices"]
        return symbols
    }

    func testParityControlsReadBackAndDoNotClaimSystemAuthentication() {
        let preferences = SafariParityPreferences()
        let report = apply(adapter(.safariAPIs, symbols: paritySymbols, preferences: preferences))
        XCTAssertEqual(preferences.stored, ["legacy": false, "auth": true, "authServices": true])
        XCTAssertEqual(report[.safariAPIs].name, "active")
        XCTAssertEqual(report[.legacyDOMEvents].name, "degraded")
        XCTAssertTrue(report[.legacyDOMEvents].detail?.contains("OverflowEvent") == true)
        XCTAssertEqual(report[.webAuthentication].name, "unverified")
        XCTAssertTrue(report[.webAuthentication].detail?.contains("platform authenticator") == true)
        XCTAssertTrue(report[.safariAPIs].detail?.contains("Web Push delivery") == true)
    }

    func testMissingParityFeatureDoesNotMutateItsGroupOrLeakIdentifiers() {
        let preferences = SafariParityPreferences()
        let diagnostics = SPIDiagnostics()
        var symbols = paritySymbols
        symbols.authenticationFeatureKeys = ["auth", "safarierSensitiveMissingFeature"]
        let report = apply(adapter(.safariAPIs, symbols: symbols, diagnostics: diagnostics, preferences: preferences))
        XCTAssertEqual(report[.webAuthentication].name, "unavailable")
        XCTAssertEqual(preferences.stored["auth"], false)
        XCTAssertEqual(preferences.stored["authServices"], false)
        XCTAssertFalse(preferences.writes.contains { $0.0 == "auth" })
        XCTAssertFalse(diagnostics.entries.joined().contains("safarierSensitiveMissingFeature"))
    }

    func testFailedParityReadbackRestoresEarlierFeatureWrites() {
        let preferences = SafariParityPreferences()
        preferences.ignoredKeys = ["authServices"]
        let report = apply(adapter(.safariAPIs, symbols: paritySymbols, preferences: preferences))
        XCTAssertEqual(report[.webAuthentication].name, "degraded")
        XCTAssertEqual(preferences.stored["auth"], false)
        XCTAssertEqual(preferences.stored["authServices"], false)
        XCTAssertTrue(report[.webAuthentication].detail?.contains("original values restored") == true)
        XCTAssertEqual(preferences.stored["legacy"], false)
    }

    func testWrongParityFeatureKeySignatureLeavesDefaultsAndReportsUnsupported() {
        let preferences = SafariParityPreferences()
        var symbols = paritySymbols
        symbols.featureKeyGetter = "safarierParityWrongKey"
        let report = apply(adapter(.safariAPIs, symbols: symbols, preferences: preferences))
        XCTAssertEqual(report[.legacyDOMEvents].name, "unavailable")
        XCTAssertEqual(report[.webAuthentication].name, "unavailable")
        XCTAssertTrue(preferences.writes.isEmpty)
    }

    func testParityFeatureControlsAreOptIn() {
        let preferences = SafariParityPreferences()
        let report = apply(adapter([], symbols: paritySymbols, preferences: preferences))
        XCTAssertTrue(preferences.writes.isEmpty)
        XCTAssertEqual(report[.legacyDOMEvents], .notRequested)
        XCTAssertEqual(report[.webAuthentication].name, "unverified")
    }

    func testRealAuthenticationControlsAreEnabledButAvailabilityRemainsUnverified() throws {
        let configuration = WKWebViewConfiguration()
        var report = PrivacyCapabilityReport()
        SPIPrivacyAdapter(features: .safariAPIs).apply(to: configuration, for: tokyo, report: &report)
        XCTAssertNotEqual(report[.webAuthentication].name, "active")
        let symbols = SPIPrivacyAdapter.Symbols.webKit
        let cls = try XCTUnwrap((WKPreferences.self as AnyObject) as? NSObject)
        guard case .success(let value?) = SPIRuntimeBridge.getObject(symbols.featuresGetter, on: cls),
              let available = value as? [NSObject] else {
            return XCTAssertEqual(report[.webAuthentication].name, "unavailable")
        }
        for key in symbols.authenticationFeatureKeys {
            guard let feature = available.first(where: {
                guard case .success(let value) = SPIRuntimeBridge.getObject(symbols.featureKeyGetter, on: $0) else { return false }
                return value as? String == key
            }) else { return XCTAssertEqual(report[.webAuthentication].name, "unavailable") }
            XCTAssertTrue(try SPIRuntimeBridge.getBool(symbols.featureGetter, with: feature, on: configuration.preferences).get())
        }
        XCTAssertEqual(report[.webAuthentication].name, "unverified")
    }

    // MARK: - webgpu

    func testWebGPUWithoutFeatureAPIIsUnavailable() {
        XCTAssertEqual(apply(adapter(.webGPU))[.webGPU].name, "unavailable")
        XCTAssertEqual(apply(adapter([]))[.webGPU], .notRequested)
    }

    /// 真实引擎：通过通用特性开关打开图形能力，并回读一致。
    func testGraphicsFeaturesRoundTripOnRealWebKit() throws {
        let configuration = WKWebViewConfiguration()
        var report = PrivacyCapabilityReport()
        SPIPrivacyAdapter(features: .webGPU).apply(to: configuration, for: tokyo, report: &report)
        guard (WKPreferences.self as AnyObject).responds(to: NSSelectorFromString(SPIPrivacyAdapter.Symbols.webKit.featuresGetter)) else {
            return XCTAssertEqual(report[.webGPU].name, "unavailable")
        }
        XCTAssertEqual(report[.webGPU].name, "active", report[.webGPU].summary)
        let features = try XCTUnwrap((WKPreferences.self as AnyObject).value(forKey: SPIPrivacyAdapter.Symbols.webKit.featuresGetter) as? [NSObject])
        for key in SPIPrivacyAdapter.Symbols.webKit.webGPUFeatureKeys {
            let feature = try XCTUnwrap(features.first { ($0.value(forKey: "key") as? String) == key })
            XCTAssertEqual(try SPIRuntimeBridge.getBool(SPIPrivacyAdapter.Symbols.webKit.featureGetter, with: feature, on: configuration.preferences).get(), true, key)
        }
    }

    // MARK: - 真实 WebKit

    /// 本机 WebKit 有对应接口时必须 active；没有时必须降级为 unavailable，且不崩溃。
    func testRealWebKitAppliesWhatThisSystemSupports() throws {
        let configuration = WKWebViewConfiguration()
        let poolBefore = try SPIRuntimeBridge.getObject(SFRSymbolDecoder.decode([0x2A, 0x28, 0x35, 0x39, 0x3F, 0x29, 0x29, 0x0A, 0x35, 0x35, 0x36]), on: configuration).get()
        var report = PrivacyCapabilityReport()
        SPIPrivacyAdapter(features: .all).apply(to: configuration, for: tokyo, report: &report)

        let symbols = SPIPrivacyAdapter.Symbols.webKit
        let hasPolicy = WKWebpagePreferences.instancesRespond(to: NSSelectorFromString(symbols.networkPolicySetter))
        let hasPeerConnection = WKPreferences.instancesRespond(to: NSSelectorFromString(symbols.peerConnectionSetter))
        let hasTimeZone = NSClassFromString(symbols.processPoolConfigurationClass) != nil
        let hasSafariAPIs = symbols.safariAPISwitches.allSatisfy { WKPreferences.instancesRespond(to: NSSelectorFromString($0.setter)) }
            && WKPreferences.instancesRespond(to: NSSelectorFromString(symbols.applePayDisclosureSetter))
        let hasFeatureAPI = (WKPreferences.self as AnyObject).responds(to: NSSelectorFromString(symbols.featuresGetter))

        XCTAssertEqual(report[.advancedPrivacyProtections].name, hasPolicy ? "active" : "unavailable", report[.advancedPrivacyProtections].summary)
        XCTAssertEqual(report[.webRTCDisabled].name, hasPeerConnection ? "active" : "unavailable", report[.webRTCDisabled].summary)
        XCTAssertEqual(report[.timeZone].name, hasTimeZone ? "active" : "unavailable", report[.timeZone].summary)
        XCTAssertEqual(report[.safariAPIs].name, hasSafariAPIs ? "active" : "unavailable", report[.safariAPIs].summary)
        XCTAssertEqual(report[.webGPU].name, hasFeatureAPI ? "active" : "unavailable", report[.webGPU].summary)
        if hasSafariAPIs {
            XCTAssertFalse(try SPIRuntimeBridge.getBool(symbols.applePayDisclosureGetter, on: configuration.preferences).get())
            for item in symbols.safariAPISwitches {
                XCTAssertEqual(try SPIRuntimeBridge.getBool(item.getter, on: configuration.preferences).get(), true, item.getter)
            }
            XCTAssertEqual(try SPIRuntimeBridge.getBool(symbols.userInstalledFontsGetter, on: configuration.preferences).get(), false)
            // Safari 另设的 5 个行为默认值：本机有的都要是 Safari 的值。
            for item in symbols.safariBehaviorSwitches where WKPreferences.instancesRespond(to: NSSelectorFromString(item.setter)) {
                XCTAssertEqual(try SPIRuntimeBridge.getBool(item.getter, on: configuration.preferences).get(), item.value, item.label)
            }
            XCTAssertTrue(report[.safariAPIs].summary.contains("Safari 行为默认值"), report[.safariAPIs].summary)
        }

        if hasPeerConnection {
            XCTAssertEqual(try SPIRuntimeBridge.getBool(symbols.peerConnectionGetter, on: configuration.preferences).get(), false)
        }
        if hasPolicy {
            let policy = try SPIRuntimeBridge.getUInt(symbols.networkPolicyGetter, on: configuration.defaultWebpagePreferences).get()
            XCTAssertEqual(policy & 0x1C1, 0x1C1, "和 Safari 无痕的高级隐私保护一样是 0x1c1")
            if WKWebpagePreferences.instancesRespond(to: NSSelectorFromString(symbols.networkPolicyEnabledGetter)) {
                XCTAssertTrue(try SPIRuntimeBridge.getBool(symbols.networkPolicyEnabledGetter, on: configuration.defaultWebpagePreferences).get(),
                              "引擎总开关必须是 YES")
                XCTAssertTrue(report[.advancedPrivacyProtections].summary.contains("引擎总开关回读 YES"), report[.advancedPrivacyProtections].summary)
            }
        }
        if hasTimeZone {
            let poolAfter = try SPIRuntimeBridge.getObject(SFRSymbolDecoder.decode([0x2A, 0x28, 0x35, 0x39, 0x3F, 0x29, 0x29, 0x0A, 0x35, 0x35, 0x36]), on: configuration).get()
            XCTAssertFalse(poolAfter === poolBefore, "应当换成带时区配置的独立进程池")
        }
    }

    func testRealWebKitWithMissingSymbolsDegradesAndLeavesConfigurationAlone() throws {
        var symbols = SPIPrivacyAdapter.Symbols()
        symbols.networkPolicyGetter = "_safarierNoSuchPolicy"
        symbols.networkPolicySetter = "_setSafarierNoSuchPolicy:"
        symbols.peerConnectionGetter = "_safarierNoSuchPeerConnection"
        symbols.peerConnectionSetter = "_setSafarierNoSuchPeerConnection:"
        symbols.processPoolConfigurationClass = "_SafarierNoSuchProcessPoolConfiguration"
        symbols.safariAPISwitches = [("_safarierNoSuchApplePay", "_setSafarierNoSuchApplePay:", "ApplePaySession")]
        symbols.featuresGetter = "_safarierNoSuchFeatures"

        let configuration = WKWebViewConfiguration()
        let poolBefore = try SPIRuntimeBridge.getObject(SFRSymbolDecoder.decode([0x2A, 0x28, 0x35, 0x39, 0x3F, 0x29, 0x29, 0x0A, 0x35, 0x35, 0x36]), on: configuration).get()
        let diagnostics = SPIDiagnostics()
        var report = PrivacyCapabilityReport()
        // fontlist 走 C 导出、不受这里换掉的 selector 影响，在 FontAllowlistAdapterTests 里用注入的桥单独测。
        let features = SPIFeatures.all.subtracting(.fontAllowlist)
        SPIPrivacyAdapter(features: features, symbols: symbols, diagnostics: diagnostics).apply(to: configuration, for: tokyo, report: &report)

        XCTAssertEqual(report[.fontAllowlist], .notRequested)
        for feature in [PrivacyFeature.advancedPrivacyProtections, .webRTCDisabled, .timeZone, .safariAPIs, .webGPU] {
            XCTAssertEqual(report[feature].name, "unavailable", "\(feature): \(report[feature].summary)")
        }
        XCTAssertEqual(diagnostics.entries.count, 7)
        XCTAssertTrue(try SPIRuntimeBridge.getObject(SFRSymbolDecoder.decode([0x2A, 0x28, 0x35, 0x39, 0x3F, 0x29, 0x29, 0x0A, 0x35, 0x35, 0x36]), on: configuration).get() === poolBefore)
    }

    // MARK: - 网页打开的弹窗

    private let processPoolGetter = SFRSymbolDecoder.decode([0x2A, 0x28, 0x35, 0x39, 0x3F, 0x29, 0x29, 0x0A, 0x35, 0x35, 0x36])

    /// 弹窗只对齐页面级设置：时区、字体白名单就算开着也不碰（它们在进程池上），逐项诊断不进会话日志。
    func testPopupAlignmentSkipsPoolFeaturesAndKeepsSessionDiagnosticsQuiet() {
        let diagnostics = SPIDiagnostics()
        let webpage = EngineLikePolicyPreferences()
        var report = PrivacyCapabilityReport()
        adapter([.fingerprintingProtections, .engineTimeZone, .fontAllowlist], diagnostics: diagnostics, webpage: webpage)
            .applyToPopup(WKWebViewConfiguration(), for: tokyo, report: &report)
        XCTAssertEqual(webpage.stored, 0x1C1)
        XCTAssertEqual(report[.advancedPrivacyProtections].name, "active", report[.advancedPrivacyProtections].summary)
        XCTAssertEqual(report[.timeZone], .unavailable("未评估"))
        XCTAssertEqual(report[.fontAllowlist], .unavailable("未评估"))
        XCTAssertTrue(diagnostics.entries.isEmpty, "每个弹窗都会走一遍，逐项诊断不进会话日志：\(diagnostics.entries)")
        XCTAssertEqual(SPIPrivacyAdapter.popupFeatures, [.fingerprintingProtections, .disableWebRTC, .safariAPIs, .webGPU])
    }

    /// 真实 WebKit：在弹窗配置上补齐 0x1c1、Safari 开关、关 WebRTC；进程池、网站数据存储、preferences 对象原样不动
    /// （window.opener 和 related page 关系靠它们），profile 开着的时区和字体白名单不在弹窗上重设。
    func testApplyToPopupAlignsPageSettingsWithoutReplacingPoolOrStore() throws {
        let popup = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        popup.websiteDataStore = store
        let poolBefore = try SPIRuntimeBridge.getObject(processPoolGetter, on: popup).get()
        let preferencesBefore = popup.preferences
        let symbols = SPIPrivacyAdapter.Symbols.webKit
        let hasPolicy = WKWebpagePreferences.instancesRespond(to: NSSelectorFromString(symbols.networkPolicySetter))
        if hasPolicy {
            XCTAssertEqual(try SPIRuntimeBridge.getUInt(symbols.networkPolicyGetter, on: popup.defaultWebpagePreferences).get() & 0x1C1, 0, "新配置还没有高级隐私保护位")
        }

        let spi = SPIPrivacyAdapter(features: .all, fontAllowlistPlanner: { _ in
            XCTFail("弹窗不应规划字体白名单")
            return FontAllowlistPlan(names: [], excludedFamilies: [], excludedFontCount: 0, sharedNamesDropped: 0)
        })
        var report = PrivacyCapabilityReport()
        CompositePrivacyAdapter([PublicAPIPrivacyAdapter(), spi]).applyToPopup(popup, for: tokyo, report: &report)

        XCTAssertTrue(try SPIRuntimeBridge.getObject(processPoolGetter, on: popup).get() === poolBefore, "不换进程池")
        XCTAssertTrue(popup.websiteDataStore === store, "不换网站数据存储")
        XCTAssertTrue(popup.preferences === preferencesBefore)
        XCTAssertEqual(report[.timeZone], .unavailable("未评估"), "引擎层时区不在弹窗上重设")
        XCTAssertEqual(report[.fontAllowlist], .unavailable("未评估"), "字体白名单不在弹窗上重设")

        if hasPolicy {
            XCTAssertEqual(report[.advancedPrivacyProtections].name, "active", report[.advancedPrivacyProtections].summary)
            XCTAssertEqual(try SPIRuntimeBridge.getUInt(symbols.networkPolicyGetter, on: popup.defaultWebpagePreferences).get() & 0x1C1, 0x1C1)
            if WKWebpagePreferences.instancesRespond(to: NSSelectorFromString(symbols.networkPolicyEnabledGetter)) {
                XCTAssertTrue(try SPIRuntimeBridge.getBool(symbols.networkPolicyEnabledGetter, on: popup.defaultWebpagePreferences).get())
            }
        }
        if symbols.safariAPISwitches.allSatisfy({ WKPreferences.instancesRespond(to: NSSelectorFromString($0.setter)) }) {
            XCTAssertEqual(report[.safariAPIs].name, "active", report[.safariAPIs].summary)
            for item in symbols.safariAPISwitches {
                XCTAssertTrue(try SPIRuntimeBridge.getBool(item.getter, on: popup.preferences).get(), item.exposes)
            }
            XCTAssertFalse(try SPIRuntimeBridge.getBool(symbols.userInstalledFontsGetter, on: popup.preferences).get())
        }
        if WKPreferences.instancesRespond(to: NSSelectorFromString(symbols.peerConnectionSetter)) {
            XCTAssertEqual(report[.webRTCDisabled].name, "active", report[.webRTCDisabled].summary)
            XCTAssertFalse(try SPIRuntimeBridge.getBool(symbols.peerConnectionGetter, on: popup.preferences).get())
        }
    }

    // MARK: - 明文

    /// 编码的私有接口名（下划线或 WK 开头，以及 12 个字符以上的标识）只能以编码形式出现在源码里；
    /// 真实 WebKit 上跑完全部能力（含弹窗）后，诊断和能力报告里也不能出现。失败信息只报长度，不打印名字。
    func testEncodedPrivateSymbolsNeverAppearInPlaintext() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let swiftArrays = try NSRegularExpression(pattern: #"decode\(\[([0-9xA-Fa-f,\s]+)\]\)"#)
        let cArrays = try NSRegularExpression(pattern: #"\{\s*(0x[0-9A-Fa-f]{2}(?:\s*,\s*0x[0-9A-Fa-f]{2})+)\s*\}"#)
        var files: [(name: String, text: String)] = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where ["swift", "m", "h", "c"].contains(url.pathExtension) {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        var encoded = Set<String>()
        for file in files {
            for pattern in [swiftArrays, cArrays] {
                for match in pattern.matches(in: file.text, range: NSRange(file.text.startIndex..., in: file.text)) {
                    guard let range = Range(match.range(at: 1), in: file.text) else { continue }
                    let bytes = file.text[range].split(separator: ",").compactMap {
                        UInt8($0.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(2), radix: 16)
                    }
                    encoded.insert(SFRSymbolDecoder.decode(bytes))
                }
            }
        }
        let sensitive = encoded.filter { $0.hasPrefix("_") || $0.hasPrefix("WK") || $0.count >= 12 }
        XCTAssertTrue(sensitive.contains(SPIPrivacyAdapter.Symbols.webKit.networkPolicyEnabledGetter), "新加的总开关读法也是编码的")
        XCTAssertGreaterThan(sensitive.count, 30)
        for file in files {
            for name in sensitive where file.text.contains(name) {
                XCTFail("\(file.name) 里出现了编码标识的明文（\(name.count) 个字符）")
            }
        }

        let diagnostics = SPIDiagnostics()
        var report = PrivacyCapabilityReport()
        let spi = SPIPrivacyAdapter(features: .all, diagnostics: diagnostics)
        spi.apply(to: WKWebViewConfiguration(), for: tokyo, report: &report)
        spi.applyToPopup(WKWebViewConfiguration(), for: tokyo, report: &report)
        let output = (diagnostics.entries + report.lines()).joined(separator: "\n")
        XCTAssertFalse(output.isEmpty)
        for name in sensitive where output.contains(name) {
            XCTFail("诊断或能力报告里出现了编码标识的明文（\(name.count) 个字符）")
        }
    }
}

@MainActor
private final class SafariParityFeature: NSObject {
    let identifier: String
    init(_ identifier: String) { self.identifier = identifier }
    @objc(safarierParityKey) var featureKey: NSString { identifier as NSString }
    @objc(safarierParityWrongKey) var wrongKey: Bool { true }
}

@MainActor
private final class SafariParityPreferences: NSObject {
    var stored = ["legacy": true, "auth": false, "authServices": false]
    var ignoredKeys: Set<String> = []
    var writes: [(String, Bool)] = []
    private var disclosure = true
    private var applePay = false
    private var push = false
    private var mediaDevices = false
    private var userFonts = true

    @objc(safarierParityFeatures) class var featureList: [NSObject] {
        [SafariParityFeature("legacy"), SafariParityFeature("auth"), SafariParityFeature("authServices")]
    }
    @objc(safarierParityEnabled:) func featureEnabled(_ feature: NSObject) -> Bool {
        guard let feature = feature as? SafariParityFeature else { return false }
        return stored[feature.identifier] ?? false
    }
    @objc(setSafarierParityEnabled:feature:) func setFeatureEnabled(_ enabled: Bool, feature: NSObject) {
        guard let feature = feature as? SafariParityFeature else { return }
        writes.append((feature.identifier, enabled))
        if !ignoredKeys.contains(feature.identifier) { stored[feature.identifier] = enabled }
    }
    @objc(safarierMockApplePayDisclosure) var disclosureAllowed: Bool { disclosure }
    @objc(setSafarierMockApplePayDisclosure:) func setDisclosure(_ value: Bool) { disclosure = value }
    @objc(safarierMockApplePay) var applePayEnabled: Bool { applePay }
    @objc(setSafarierMockApplePay:) func setApplePay(_ value: Bool) { applePay = value }
    @objc(safarierMockPushAPI) var pushAPIEnabled: Bool { push }
    @objc(setSafarierMockPushAPI:) func setPush(_ value: Bool) { push = value }
    @objc(safarierMockMediaDevices) var mediaDevicesEnabled: Bool { mediaDevices }
    @objc(setSafarierMockMediaDevices:) func setMediaDevices(_ value: Bool) { mediaDevices = value }
    @objc(safarierMockUserFonts) var userFontsEnabled: Bool { userFonts }
    @objc(setSafarierMockUserFonts:) func setUserFonts(_ value: Bool) { userFonts = value }
}
