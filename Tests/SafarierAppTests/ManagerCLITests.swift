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

    func testCLIProfileCreateUpdateAndConflictsForBypassSystemProxy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = ProcessInfo.processInfo.environment["SAFARIER_HOME"]
        setenv("SAFARIER_HOME", root.path, 1)
        defer { if let previous { setenv("SAFARIER_HOME", previous, 1) } else { unsetenv("SAFARIER_HOME") } }
        let workspace = SafarierWorkspace(root: root)
        let proxy = ProxySettings(name: "P", kind: .socks5, host: "192.0.2.10", port: 1080)
        try workspace.proxies.insert(proxy)

        XCTAssertEqual(ManagerCLI.run(["profile", "create", "--name", "LocalOnly", "--bypass-system-proxy"]), 0)
        let created = try XCTUnwrap(workspace.profiles.all().first { $0.name == "LocalOnly" })
        XCTAssertTrue(created.bypassSystemProxy)
        XCTAssertFalse(created.hasOutboundProxy)
        XCTAssertEqual(ManagerCLI.run(["profile", "list"]), 0)

        XCTAssertNotEqual(ManagerCLI.run(["profile", "create", "--name", "Conflict", "--bypass-system-proxy", "--proxy", proxy.id.uuidString]), 0)
        XCTAssertNotEqual(ManagerCLI.run(["profile", "update", created.id.uuidString, "--bypass-system-proxy", "--no-bypass-system-proxy"]), 0)

        XCTAssertEqual(ManagerCLI.run(["profile", "update", created.id.uuidString, "--no-bypass-system-proxy"]), 0)
        XCTAssertEqual(try workspace.profiles.record(id: created.id)?.bypassSystemProxy, false)

        XCTAssertEqual(ManagerCLI.run(["profile", "update", created.id.uuidString, "--proxy", proxy.id.uuidString]), 0)
        XCTAssertNotEqual(ManagerCLI.run(["profile", "update", created.id.uuidString, "--bypass-system-proxy"]), 0, "未显式解绑代理时应拒绝直接开启本机直连")
        XCTAssertNotEqual(ManagerCLI.run(["profile", "update", created.id.uuidString, "--node", "none", "--bypass-system-proxy"]), 0, "仅传 --node none 时仍保留独立代理，必须拒绝开启本机直连")
        XCTAssertEqual(try workspace.profiles.record(id: created.id)?.proxyID, proxy.id, "失败后原独立代理必须保持完整不被清空")
        XCTAssertEqual(ManagerCLI.run(["profile", "update", created.id.uuidString, "--proxy", "none", "--bypass-system-proxy"]), 0)
        let updated = try XCTUnwrap(workspace.profiles.record(id: created.id))
        XCTAssertNil(updated.proxyID)
        XCTAssertTrue(updated.bypassSystemProxy)

        XCTAssertNotEqual(ManagerCLI.run(["profile", "create", "--name", "InvalidFollow", "--bypass-system-proxy", "--lang", "proxy"]), 0, "本机网络直连不允许跟随代理语言")
        XCTAssertNotEqual(ManagerCLI.run(["profile", "update", created.id.uuidString, "--tz", "proxy"]), 0, "直连/本机网络环境不允许更新为跟随代理时区")
    }
}
