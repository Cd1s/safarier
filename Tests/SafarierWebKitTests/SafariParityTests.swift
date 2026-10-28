import XCTest
import AppKit
import WebKit
import SafarierCore
@testable import SafarierWebKit

/// UA 版本与内核对齐、Safari 默认设置、机型像素比。
final class SafariParityTests: XCTestCase {
    func testReleaseFamilyMappingsCoverSupportedMacOSBundlePrefixes() {
        let families = [
            ("616.1.27", "17.0"), ("616.2.9", "17.1"),
            ("617.1.17", "17.2"), ("617.2.4", "17.3"),
            ("618.1.15", "17.4"), ("618.2.12", "17.5"), ("618.3.11", "17.6"),
            ("619.1.26", "18.0"), ("619.2.8", "18.1"),
            ("620.1.16", "18.2"), ("620.2.4", "18.3"),
            ("621.1.15", "18.4"), ("621.2.5", "18.5"), ("621.3.11.11.3", "18.6"),
            ("622.1.22", "26.0"), ("622.2.11", "26.1"),
            ("623.1.14", "26.2"), ("623.2.7", "26.3"),
            ("624.1.16", "26.4"), ("624.2.5", "26.5"), ("624.4.5", "26.6"),
        ]
        for platform in ["19", "20", "21"] {
            for (engine, safari) in families {
                let baseline = SafarierWebKitInfo.engineBaseline(loadedWebKit: platform + engine, installedSafari: "27.0", safariStagedWebKit: "20625.1.29.18.28")
                XCTAssertEqual(baseline.selectedSafariVersion, safari, platform + engine)
                XCTAssertTrue(baseline.matchesEngine)
            }
        }
    }

    func testMissingMetadataDoesNotClaimSharedEngineOrBroadVersionMatch() {
        let missingStaged = SafarierWebKitInfo.engineBaseline(loadedWebKit: "20621.3.11", installedSafari: "27.0", safariStagedWebKit: nil)
        XCTAssertEqual(missingStaged.relationship, .unverified)
        XCTAssertEqual(missingStaged.selectedSafariVersion, "18.6")
        XCTAssertFalse(missingStaged.hasStagedEngineMismatch)
        for version in [nil, "", "21699.1.1", "20621.30.1", "20621.3.bad"] as [String?] {
            let baseline = SafarierWebKitInfo.engineBaseline(loadedWebKit: version, installedSafari: "27.0", safariStagedWebKit: nil)
            XCTAssertFalse(baseline.matchesEngine)
            XCTAssertEqual(baseline.relationship, .unverified)
            XCTAssertNil(baseline.mappedSafariVersion)
        }
        let noSafari = SafarierWebKitInfo.engineBaseline(loadedWebKit: "19618.3.11", installedSafari: " ", safariStagedWebKit: "")
        XCTAssertNil(noSafari.installedSafari)
        XCTAssertNil(noSafari.safariStagedWebKit)
        XCTAssertEqual(noSafari.selectedSafariVersion, "17.6")
    }

    func testStructuredBaselineRoundTripsAndOldReportsStillDecode() throws {
        let baseline = SafarierWebKitInfo.engineBaseline(loadedWebKit: "20621.3.11.11.3", installedSafari: "27.0", safariStagedWebKit: "20625.1.29.18.28")
        XCTAssertTrue(baseline.hasStagedEngineMismatch)
        XCTAssertEqual(baseline.loadedWebKit, "20621.3.11.11.3")
        XCTAssertEqual(baseline.installedSafari, "27.0")
        XCTAssertEqual(baseline.safariStagedWebKit, "20625.1.29.18.28")
        let report = PrivacyCapabilityReport(engineBaseline: baseline)
        XCTAssertEqual(try JSONDecoder().decode(PrivacyCapabilityReport.self, from: JSONEncoder().encode(report)), report)
        let legacy = try JSONDecoder().decode(PrivacyCapabilityReport.self, from: Data(#"{"states":{}}"#.utf8))
        XCTAssertNil(legacy.engineBaseline)
    }

    @MainActor
    func testFactoryReportsEngineGapAndDoesNotClaimAuthenticatorAvailability() throws {
        let baseline = SafarierWebKitInfo.engineBaseline(loadedWebKit: "20621.3.11", installedSafari: "27.0", safariStagedWebKit: "20625.1.29")
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), engineBaseline: baseline)
        let report = try factory.make(profile: Profile(name: "audit", mode: .ephemeral), proxy: nil).report
        XCTAssertEqual(report.engineBaseline, baseline)
        XCTAssertEqual(report[.engineBaseline].name, "degraded")
        XCTAssertEqual(report[.webAuthentication].name, "unverified")
        XCTAssertTrue(report[.webAuthentication].detail?.contains("Host signing") == true)
    }
    func testUserAgentUsesInstalledSafariWhenSafariSharesOurWebKit() {
        let choice = SafarierWebKitInfo.userAgentSafariVersion(loadedWebKit: "21625.1.2", installedSafari: "27.0", safariStagedWebKit: "21625.1.2")
        XCTAssertEqual(choice?.version, "27.0")
        XCTAssertEqual(choice?.matchesEngine, true)
    }

    /// The system 621.3 family is Safari 18.6, regardless of a newer installed Safari.
    func testUserAgentFollowsLoadedEngineWhenSafariUsesStagedWebKit() {
        let choice = SafarierWebKitInfo.userAgentSafariVersion(loadedWebKit: "20621.3.11.11.3", installedSafari: "27.0", safariStagedWebKit: "20625.1.29.18.28")
        XCTAssertEqual(choice?.version, "18.6")
        XCTAssertEqual(choice?.matchesEngine, true)
        XCTAssertTrue(choice?.note.contains("20625") == true)
    }

    func testUnknownEngineKeepsInstalledVersionButReportsMismatch() {
        let choice = SafarierWebKitInfo.userAgentSafariVersion(loadedWebKit: "20999.1.1", installedSafari: "27.0", safariStagedWebKit: "21000.1.1")
        XCTAssertEqual(choice?.version, "27.0")
        XCTAssertEqual(choice?.matchesEngine, false)
        XCTAssertNil(SafarierWebKitInfo.userAgentSafariVersion(loadedWebKit: "1", installedSafari: nil, safariStagedWebKit: nil))
    }

    @MainActor
    func testFactoryAppliesSafariDefaultsAndMarksDeviceModelPending() throws {
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: "Version/18.6 Safari/605.1.15",
                                                  userAgentVersion: .init(version: "18.6", matchesEngine: false, note: "x"))
        let profile = Profile(name: "p", mode: .ephemeral, deviceModel: MacDeviceModel.macBookAir13M2.id)
        let output = try factory.make(profile: profile, proxy: nil, processLanguages: [])

        XCTAssertTrue(output.configuration.preferences.isElementFullscreenEnabled)
        XCTAssertEqual(output.configuration.mediaTypesRequiringUserActionForPlayback, .audio)
        XCTAssertTrue(output.configuration.upgradeKnownHostsToHTTPS)
        XCTAssertEqual(output.report[.deviceModel].name, "unverified")
        XCTAssertEqual(output.report[.safariUserAgent].name, "degraded", "UA 与内核对不上时要如实报告")
        XCTAssertEqual(try factory.make(profile: Profile(name: "q", mode: .ephemeral), proxy: nil, processLanguages: []).report[.deviceModel], .notRequested)
    }

    /// 真实 WKWebView：像素比覆盖接口存在时必须生效并回读一致。
    @MainActor
    func testDeviceSimulationSetsPixelRatioOnRealWebView() throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: WKWebViewConfiguration())
        let state = DeviceSimulation(model: .macBookPro16M3Max, diagnostics: SPIDiagnostics()).apply(to: webView)
        guard WKWebView.instancesRespond(to: NSSelectorFromString(DeviceSimulation.setter)) else {
            return XCTAssertEqual(state.name, "unavailable")
        }
        XCTAssertEqual(state.name, "active", state.summary)
        XCTAssertEqual(try SPIRuntimeBridge.getDouble(DeviceSimulation.getter, on: webView).get(), 2)
    }

    @MainActor
    func testNativeLegacyEventControlStopsDispatchAndReportsConstructorLimit() async throws {
        let original = WKWebViewConfiguration()
        original.websiteDataStore = .nonPersistent()
        let before = try await observePage(original)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        var report = PrivacyCapabilityReport()
        SPIPrivacyAdapter(features: .safariAPIs).apply(to: configuration, for: Profile(name: "audit", mode: .ephemeral), report: &report)
        let observed = try await observePage(configuration)
        if report[.legacyDOMEvents].name == "degraded", report[.legacyDOMEvents].detail?.contains("readback verified") == true {
            XCTAssertEqual(observed["mutationEvents"] as? Int, 0)
            if before["mutation"] as? String == "function" {
                XCTAssertGreaterThan(try XCTUnwrap(before["mutationEvents"] as? Int), 0)
            }
            XCTAssertTrue(report[.legacyDOMEvents].detail?.contains("constructor exposure is not removed") == true)
            XCTAssertTrue(report[.legacyDOMEvents].detail?.contains("OverflowEvent") == true)
        } else {
            XCTAssertEqual(report[.legacyDOMEvents].name, "unavailable")
        }
        XCTAssertEqual(observed["webdriver"] as? Bool, false)
        XCTAssertEqual(observed["notification"] as? String, "function")
    }

    @MainActor
    func testAuthenticationChecksSettleWithoutClaimingHostSupport() async throws {
        for persistent in [false, true] {
            let identifier = UUID()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = persistent ? WKWebsiteDataStore(forIdentifier: identifier) : .nonPersistent()
            var report = PrivacyCapabilityReport()
            SPIPrivacyAdapter(features: .safariAPIs).apply(to: configuration, for: Profile(name: "audit", mode: persistent ? .persistent : .ephemeral), report: &report)
            let observed = try await observePage(configuration)
            XCTAssertNotEqual(report[.webAuthentication].name, "active")
            if report[.webAuthentication].name == "unverified" {
                XCTAssertEqual(observed["authenticatorStatus"] as? String, "resolved")
                XCTAssertEqual(observed["conditionalStatus"] as? String, "resolved")
                XCTAssertNotNil(observed["authenticator"] as? Bool)
                XCTAssertNotNil(observed["conditional"] as? Bool)
            }
            print("[parity] persistent=\(persistent) authenticator=\(String(describing: observed["authenticator"] as? Bool)) conditional=\(String(describing: observed["conditional"] as? Bool))")
            if persistent {
                configuration.websiteDataStore = .nonPersistent()
                for attempt in 0..<20 {
                    do { try await WKWebsiteDataStore.remove(forIdentifier: identifier); break }
                    catch {
                        if attempt == 19 { throw error }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
        }
    }

    @MainActor
    private func observePage(_ configuration: WKWebViewConfiguration) async throws -> [String: Any] {
        let loaded = expectation(description: "controlled parity page loaded")
        let observer = SafariParityNavigationObserver(loaded: loaded)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 640, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.navigationDelegate = observer
        window.orderBack(nil)
        defer { view.stopLoading(); view.navigationDelegate = nil; window.contentView = nil; window.close() }
        view.loadHTMLString("<!doctype html><meta charset=utf-8><title>Engine parity check</title>", baseURL: URL(string: "https://example.com/"))
        await fulfillment(of: [loaded], timeout: 15)
        if let error = observer.error { throw error }
        let script = """
        const check = async name => {
          if (typeof PublicKeyCredential === 'undefined' || typeof PublicKeyCredential[name] !== 'function') return {status: 'absent'};
          let timer;
          try { return {status: 'resolved', value: await Promise.race([PublicKeyCredential[name](), new Promise((_, reject) => {timer = setTimeout(() => reject(new Error('timeout')), 3000);})])}; }
          catch (error) { return {status: 'rejected', error: error.name}; }
          finally {clearTimeout(timer);}
        };
        const authenticator = await check('isUserVerifyingPlatformAuthenticatorAvailable');
        const conditional = await check('isConditionalMediationAvailable');
        const node = document.createElement('div');
        document.body.appendChild(node);
        let mutationEvents = 0;
        node.addEventListener('DOMSubtreeModified', () => mutationEvents++);
        node.appendChild(document.createElement('span'));
        node.remove();
        return {mutation: typeof MutationEvent, overflow: typeof OverflowEvent, notification: typeof Notification,
          mutationEvents,
          webdriver: navigator.webdriver, authenticatorStatus: authenticator.status, conditionalStatus: conditional.status,
          authenticator: authenticator.value, conditional: conditional.value};
        """
        let completed = expectation(description: "bounded parity checks completed")
        var outcome: Result<Any, Error>?
        view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            outcome = result
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 10)
        return try XCTUnwrap(try XCTUnwrap(outcome).get() as? [String: Any])
    }
}

@MainActor
private final class SafariParityNavigationObserver: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    var error: Error?
    private var completed = false

    init(loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    private func finish(_ failure: Error?) {
        guard !completed else { return }
        completed = true
        error = failure
        loaded.fulfill()
    }
}
