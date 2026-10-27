import XCTest
import WebKit
import SafarierCore
@testable import SafarierWebKit

final class WebViewConfigurationFactoryTests: XCTestCase {
    @MainActor
    private func makeFactory(credentials: InMemoryCredentialStore = InMemoryCredentialStore(), safariName: String? = "Version/27.0 Safari/605.1.15") -> WebViewConfigurationFactory {
        WebViewConfigurationFactory(credentials: credentials, safariApplicationName: safariName)
    }

    @MainActor
    func testEphemeralProfileWithoutProxyReportsHonestly() throws {
        let profile = Profile(name: "p", mode: .ephemeral, languages: ["de-DE", "de"], timeZoneIdentifier: "Europe/Berlin")
        let output = try makeFactory().make(profile: profile, proxy: nil, processLanguages: ["de-DE", "de"])

        XCTAssertFalse(output.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(output.configuration.websiteDataStore.proxyConfigurations.isEmpty)
        XCTAssertEqual(output.configuration.applicationNameForUserAgent, "Version/27.0 Safari/605.1.15")

        let report = output.report
        XCTAssertEqual(report[.proxy], .notRequested)
        guard case .active = report[.dataIsolation] else { return XCTFail("dataIsolation: \(report[.dataIsolation])") }
        guard case .active = report[.languages] else { return XCTFail("languages: \(report[.languages])") }
        guard case .active = report[.safariUserAgent] else { return XCTFail("UA: \(report[.safariUserAgent])") }
        // TZ 传不到 WebContent（M0-2），没有引擎层适配器时必须报告为做不到。
        guard case .unavailable = report[.timeZone] else { return XCTFail("timeZone: \(report[.timeZone])") }
        // 默认适配器不碰原生引擎接口。
        guard case .unavailable = report[.advancedPrivacyProtections] else { return XCTFail() }
        guard case .unavailable = report[.webRTCDisabled] else { return XCTFail() }
    }

    @MainActor
    func testLanguagesNotPassedToProcessAreUnavailable() throws {
        let profile = Profile(name: "p", mode: .ephemeral, languages: ["ja-JP"])
        let report = try makeFactory().make(profile: profile, proxy: nil, processLanguages: ["en-US"]).report
        guard case .unavailable = report[.languages] else { return XCTFail("languages: \(report[.languages])") }
        XCTAssertEqual(report[.timeZone], .notRequested)

        // 泰语：Runner 带上 th-TH/th 才算生效；只剩宿主机的语言（例如 zh-Hant-SG）时如实报告做不到。
        let thai = Profile(name: "th", mode: .ephemeral, languages: ["th-TH", "th"])
        guard case .active = try makeFactory().make(profile: thai, proxy: nil, processLanguages: ["th-TH", "th"]).report[.languages] else {
            return XCTFail("th-TH 应当 active")
        }
        guard case .unavailable = try makeFactory().make(profile: thai, proxy: nil, processLanguages: ["zh-Hant-SG", "en-SG"]).report[.languages] else {
            return XCTFail("宿主机语言不应算作 th-TH")
        }
    }

    @MainActor
    func testProxyIsAppliedWithKeychainPassword() throws {
        let credentials = InMemoryCredentialStore()
        let proxy = ProxySettings(name: "x", kind: .socks5, host: "127.0.0.1", port: 20001, username: "u")
        try credentials.setPassword("secret", forKey: proxy.credentialKey)
        let profile = Profile(name: "p", mode: .ephemeral, proxyID: proxy.id)

        let output = try makeFactory(credentials: credentials).make(profile: profile, proxy: proxy, processLanguages: [])

        XCTAssertEqual(output.configuration.websiteDataStore.proxyConfigurations.count, 1)
        guard case .active = output.report[.proxy] else { return XCTFail("proxy: \(output.report[.proxy])") }
    }

    @MainActor
    func testMissingOrMismatchedProxyFailsInsteadOfGoingDirect() {
        let proxy = ProxySettings(name: "x", kind: .socks5, host: "127.0.0.1", port: 20001)
        let profile = Profile(name: "p", mode: .ephemeral, proxyID: proxy.id)
        let factory = makeFactory()

        XCTAssertThrowsError(try factory.make(profile: profile, proxy: nil, processLanguages: [])) {
            XCTAssertEqual($0 as? WebViewConfigurationError, .proxyNotFound(proxy.id))
        }
        let other = ProxySettings(name: "y", kind: .socks5, host: "127.0.0.1", port: 20002)
        XCTAssertThrowsError(try factory.make(profile: profile, proxy: other, processLanguages: [])) {
            XCTAssertEqual($0 as? WebViewConfigurationError, .proxyMismatch(expected: proxy.id, got: other.id))
        }
    }

    @MainActor
    func testWithoutSafariKeepsDefaultUserAgent() throws {
        let output = try makeFactory(safariName: nil).make(profile: Profile(name: "p", mode: .ephemeral), proxy: nil, processLanguages: [])
        XCTAssertNil(output.configuration.applicationNameForUserAgent.flatMap { $0.isEmpty ? nil : $0 })
        guard case .unavailable = output.report[.safariUserAgent] else { return XCTFail() }
    }

    func testSafariApplicationNameFormat() {
        XCTAssertEqual(SafarierWebKitInfo.safariApplicationNameForUserAgent(safariVersion: "27.0"), "Version/27.0 Safari/605.1.15")
        XCTAssertNil(SafarierWebKitInfo.safariApplicationNameForUserAgent(safariVersion: ""))
    }
}
