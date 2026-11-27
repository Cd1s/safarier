import XCTest
@testable import SafarierCore

final class StartupTabsTests: XCTestCase {
    private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func profileJSON(tabs: String?, legacyURL: String? = "https://example.com/legacy") -> Data {
        var fields = ["\"id\": \"\(id)\"", "\"name\": \"Startup\"", "\"mode\": \"persistent\"", "\"createdAt\": 0"]
        if let legacyURL { fields.append("\"startURL\": \"\(legacyURL)\"") }
        if let tabs { fields.append("\"startupTabs\": \(tabs)") }
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    func testExplicitEmptyStartupListDoesNotFallBackToLegacyURL() throws {
        let profile = try JSONDecoder().decode(Profile.self, from: profileJSON(tabs: "[]"))
        let workspace = SafarierWorkspace(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertNil(workspace.runnerSpec(for: profile).startURL)
        XCTAssertNil(profile.startURL, "起始页兼容入口也不能重新打开已移除的网址")
    }

    func testPausedStartupTabsArePreservedButNeverAutoOpened() throws {
        let tabs = """
        [{"id":"AAAAAAAA-2222-3333-4444-555555555555","url":"https://example.com/paused","isEnabled":false}]
        """
        let profile = try JSONDecoder().decode(Profile.self, from: profileJSON(tabs: tabs))
        let workspace = SafarierWorkspace(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertNil(workspace.runnerSpec(for: profile).startURL)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        let savedTabs = try XCTUnwrap(saved["startupTabs"] as? [[String: Any]])
        XCTAssertEqual(savedTabs.count, 1)
        XCTAssertEqual(savedTabs.first?["isEnabled"] as? Bool, false)
    }

    func testRepeatedRunnerURLsKeepFirstURLAsHomeAndPreserveAllArguments() throws {
        let args = ["run", "--profile", id.uuidString, "--url", "https://example.com/first", "--url", "https://example.com/second"]
        let spec = try RunnerLaunchSpec.parse(args)
        XCTAssertEqual(spec.startURL?.absoluteString, "https://example.com/first")
        XCTAssertEqual(spec.arguments(), args)
    }

    func testLegacyURLMigratesWithStableIdentityAndRoundTrips() throws {
        let data = profileJSON(tabs: nil)
        let first = try JSONDecoder().decode(Profile.self, from: data)
        let second = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(first, second, "重复读取旧配置不能被误判为外部修改")
        XCTAssertEqual(first.startupTabs.count, 1)
        XCTAssertTrue(try XCTUnwrap(first.startupTabs.first).isEnabled)
        XCTAssertEqual(first.startupURLs, [URL(string: "https://example.com/legacy")!])
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(first)), first)
    }

    func testEnabledOrderOverridesProbeAndCopy() throws {
        let urls = ["first", "paused", "third"].map { URL(string: "https://example.com/\($0)")! }
        let tabs = urls.enumerated().map { StartupTab(url: $0.element, isEnabled: $0.offset != 1) }
        let profile = Profile(name: "Startup", mode: .persistent, startupTabs: tabs)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = SafarierWorkspace(root: root)
        XCTAssertEqual(workspace.runnerSpec(for: profile).startURLs, [urls[0], urls[2]])
        XCTAssertEqual(workspace.runnerSpec(for: profile, probe: true).startURLs, [urls[0]])
        XCTAssertEqual(workspace.runnerSpec(for: profile, url: urls[1]).startURLs, [urls[1]])
        let duplicated = profile.duplicated(name: "Copy")
        XCTAssertEqual(duplicated.startupTabs.map(\.url), tabs.map(\.url))
        XCTAssertEqual(duplicated.startupTabs.map(\.isEnabled), tabs.map(\.isEnabled))
        XCTAssertTrue(Set(duplicated.startupTabs.map(\.id)).isDisjoint(with: Set(tabs.map(\.id))), "复制环境应为启动页签生成新的标识")
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile)), profile)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        XCTAssertEqual(saved["startURL"] as? String, urls[0].absoluteString)

        var paused = profile
        for index in paused.startupTabs.indices { paused.startupTabs[index].isEnabled = false }
        XCTAssertTrue(workspace.runnerSpec(for: paused).startURLs.isEmpty)
        let pausedSaved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(paused)) as? [String: Any])
        XCTAssertNil(pausedSaved["startURL"])
    }

    func testInvalidPausedURLAndDuplicateIdentityAreRejected() {
        let invalid = StartupTab(url: URL(string: "https://")!, isEnabled: false)
        XCTAssertThrowsError(try Profile(name: "Invalid", mode: .persistent, startupTabs: [invalid]).validate())
        let valid = StartupTab(url: URL(string: "https://example.com")!)
        XCTAssertThrowsError(try Profile(name: "Duplicate", mode: .persistent, startupTabs: [valid, valid]).validate())
    }

    func testNullStartupTabsFallsBackSafelyWithoutFailingDecode() throws {
        let withLegacy = try JSONDecoder().decode(Profile.self, from: profileJSON(tabs: "null"))
        XCTAssertEqual(withLegacy.startupURLs, [URL(string: "https://example.com/legacy")!])
        XCTAssertEqual(withLegacy.startupTabs.first?.id, id)

        let withoutLegacy = try JSONDecoder().decode(Profile.self, from: profileJSON(tabs: "null", legacyURL: nil))
        XCTAssertEqual(withoutLegacy.startupTabs, [])
    }

    func testLanguageRelaunchPreservesEveryURLAndBackgroundFlag() throws {
        let urls = [URL(string: "https://example.com/1")!, URL(string: "https://example.com/2")!]
        let spec = RunnerLaunchSpec(profileID: id, background: true, startURLs: urls)
        let updated = RunnerLaunchSpec.replacingAppleLanguages(["en-US"], in: spec.arguments())
        let parsed = try RunnerLaunchSpec.parse(updated)
        XCTAssertEqual(parsed.startURLs, urls)
        XCTAssertTrue(parsed.background)
    }
}
