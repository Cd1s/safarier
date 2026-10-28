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
        XCTAssertEqual(SPIPrivacyAdapter.fingerprintingPolicyMask, 0x1C0)
        guard case .active(let text) = report[.advancedPrivacyProtections] else { return XCTFail("\(report[.advancedPrivacyProtections])") }
        XCTAssertTrue(text.contains("0x2 → 0x1c2"), text)
        XCTAssertTrue(diagnostics.entries.contains { $0.hasPrefix("afp：") })
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
        XCTAssertFalse(preferences.userInstalledFonts)
        guard case .active(let text) = report[.safariAPIs] else { return XCTFail("\(report[.safariAPIs])") }
        XCTAssertTrue(text.contains("ApplePaySession") && text.contains("PushManager") && text.contains("navigator.mediaDevices"), text)
        XCTAssertTrue(text.contains("关闭用户安装字体"), text)
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
        let hasFeatureAPI = (WKPreferences.self as AnyObject).responds(to: NSSelectorFromString(symbols.featuresGetter))

        XCTAssertEqual(report[.advancedPrivacyProtections].name, hasPolicy ? "active" : "unavailable", report[.advancedPrivacyProtections].summary)
        XCTAssertEqual(report[.webRTCDisabled].name, hasPeerConnection ? "active" : "unavailable", report[.webRTCDisabled].summary)
        XCTAssertEqual(report[.timeZone].name, hasTimeZone ? "active" : "unavailable", report[.timeZone].summary)
        XCTAssertEqual(report[.safariAPIs].name, hasSafariAPIs ? "active" : "unavailable", report[.safariAPIs].summary)
        XCTAssertEqual(report[.webGPU].name, hasFeatureAPI ? "active" : "unavailable", report[.webGPU].summary)
        if hasSafariAPIs {
            for item in symbols.safariAPISwitches {
                XCTAssertEqual(try SPIRuntimeBridge.getBool(item.getter, on: configuration.preferences).get(), true, item.getter)
            }
            XCTAssertEqual(try SPIRuntimeBridge.getBool(symbols.userInstalledFontsGetter, on: configuration.preferences).get(), false)
        }

        if hasPeerConnection {
            XCTAssertEqual(try SPIRuntimeBridge.getBool(symbols.peerConnectionGetter, on: configuration.preferences).get(), false)
        }
        if hasPolicy {
            let policy = try SPIRuntimeBridge.getUInt(symbols.networkPolicyGetter, on: configuration.defaultWebpagePreferences).get()
            XCTAssertEqual(policy & SPIPrivacyAdapter.fingerprintingPolicyMask, SPIPrivacyAdapter.fingerprintingPolicyMask)
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
    @objc(safarierMockApplePay) var applePayEnabled: Bool { applePay }
    @objc(setSafarierMockApplePay:) func setApplePay(_ value: Bool) { applePay = value }
    @objc(safarierMockPushAPI) var pushAPIEnabled: Bool { push }
    @objc(setSafarierMockPushAPI:) func setPush(_ value: Bool) { push = value }
    @objc(safarierMockMediaDevices) var mediaDevicesEnabled: Bool { mediaDevices }
    @objc(setSafarierMockMediaDevices:) func setMediaDevices(_ value: Bool) { mediaDevices = value }
    @objc(safarierMockUserFonts) var userFontsEnabled: Bool { userFonts }
    @objc(setSafarierMockUserFonts:) func setUserFonts(_ value: Bool) { userFonts = value }
}
