import XCTest
import SafarierCore
@testable import Safarier

/// 命令行 `--lang` / `--tz` 的来源选项和自定义值。
@MainActor
final class ManagerCLITests: XCTestCase {
    func testLanguageOption() {
        for raw in ["proxy", "auto", "PROXY"] {
            let option = ManagerCLI.parseLanguageOption(raw)
            XCTAssertTrue(option.follow, raw)
            XCTAssertEqual(option.languages, [], raw)
        }
        for raw in ["timezone", "TIMEZONE", "system", "none"] {
            let option = ManagerCLI.parseLanguageOption(raw)
            XCTAssertFalse(option.follow, raw)
            XCTAssertEqual(option.languages, [], raw)
        }
        let custom = ManagerCLI.parseLanguageOption("th-TH, th")
        XCTAssertFalse(custom.follow)
        XCTAssertEqual(custom.languages, ["th-TH", "th"])
    }

    func testTimeZoneOption() {
        for raw in ["proxy", "auto"] {
            let option = ManagerCLI.parseTimeZoneOption(raw)
            XCTAssertTrue(option.follow, raw)
            XCTAssertNil(option.identifier, raw)
        }
        for raw in ["system", "none"] {
            let option = ManagerCLI.parseTimeZoneOption(raw)
            XCTAssertFalse(option.follow, raw)
            XCTAssertNil(option.identifier, raw)
        }
        let custom = ManagerCLI.parseTimeZoneOption("Asia/Bangkok")
        XCTAssertFalse(custom.follow)
        XCTAssertEqual(custom.identifier, "Asia/Bangkok")
    }

    func testCLIUpdatesAndClearsUpstreamAndProtectsReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = ProcessInfo.processInfo.environment["SAFARIER_HOME"]
        setenv("SAFARIER_HOME", root.path, 1)
        defer { if let previous { setenv("SAFARIER_HOME", previous, 1) } else { unsetenv("SAFARIER_HOME") } }
        let workspace = SafarierWorkspace(root: root)
        let entry = ProxySettings(name: "Entry", kind: .socks5, host: "192.0.2.1", port: 1080)
        let exit = ProxySettings(name: "Exit", kind: .httpConnect, host: "192.0.2.2", port: 8080)
        try workspace.proxies.insert(entry)
        try workspace.proxies.insert(exit)
        XCTAssertEqual(ManagerCLI.run(["proxy", "update", exit.id.uuidString, "--upstream-proxy", entry.id.uuidString]), 0)
        XCTAssertEqual(try workspace.proxies.record(id: exit.id)?.upstream, .proxy(entry.id))
        XCTAssertNotEqual(ManagerCLI.run(["proxy", "delete", entry.id.uuidString]), 0)
        XCTAssertNotEqual(ManagerCLI.run(["proxy", "update", entry.id.uuidString, "--upstream-proxy", exit.id.uuidString]), 0)
        XCTAssertNotEqual(ManagerCLI.run(["proxy", "update", exit.id.uuidString, "--upstream-proxy", exit.id.uuidString]), 0)
        XCTAssertEqual(ManagerCLI.run(["proxy", "update", exit.id.uuidString, "--upstream-proxy", "none"]), 0)
        XCTAssertNil(try workspace.proxies.record(id: exit.id)?.upstream)
        XCTAssertEqual(ManagerCLI.run(["proxy", "add", "--name", "Chained", "--kind", "socks5", "--host", "192.0.2.3", "--port", "1080", "--upstream-proxy", entry.id.uuidString]), 0)
        XCTAssertEqual(try workspace.proxies.all().last?.upstream, .proxy(entry.id))
    }
}
