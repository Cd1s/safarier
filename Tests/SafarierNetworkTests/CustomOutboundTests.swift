import XCTest
import SafarierCore
@testable import SafarierNetwork

final class CustomOutboundTests: XCTestCase {
    func testCustomProxyPreservesCredentialsAndUsesManagedRouting() throws {
        for kind in ProxyKind.allCases {
            let password = "quote\"\\\nsecret"
            let json = try CustomOutbound.encoded([
                "type": .string(kind == .socks5 ? "socks" : "http"), "server": .string("127.0.0.1"),
                "server_port": .number(8080), "username": .string("user"), "password": .string(password),
            ])
            let config = try CustomOutbound.configuration(json: json, inboundPort: 23456)
            XCTAssertEqual(config.outbounds[0]["type"], .string(kind == .socks5 ? "socks" : "http"))
            XCTAssertEqual(config.outbounds[0]["password"], .string(password))
            XCTAssertEqual(config.outbounds[0]["tag"], .string("proxy"))
            XCTAssertEqual(config.inbounds[0]["listen"], .string("127.0.0.1"))
            XCTAssertEqual(config.inbounds[0]["listen_port"], .number(23456))
            XCTAssertEqual(config.route, ["final": .string("proxy")])
        }
    }

    func testAdvancedFieldsRoundTripWithoutLosingPrecision() throws {
        let json = #"{"type":"http","tag":"user-tag","server":"proxy.example","server_port":443,"tls":{"enabled":true,"server_name":"proxy.example"},"custom_numeric_option":1.25}"#
        let object = try CustomOutbound.parse(json)
        XCTAssertEqual(object["tag"], .string("proxy"))
        XCTAssertEqual(object["custom_numeric_option"], .decimal(1.25))
        XCTAssertEqual(try CustomOutbound.parse(CustomOutbound.encoded(object)), object)
    }

    func testRejectsFullConfigurationDirectGroupsAndDetours() {
        for json in ["", "[]", #"{"outbounds":[]}"#,
                     #"{"type":"direct","server":"x","server_port":1}"#,
                     #"{"type":"selector","server":"x","server_port":1}"#,
                     #"{"type":"socks","server":"x","server_port":1,"detour":"direct"}"#,
                     #"{"type":"socks","server":"x","server_port":0}"#,
                     #"{"type":"socks","server":"","server_port":1080}"#] {
            XCTAssertThrowsError(try CustomOutbound.parse(json), json)
        }
    }

    func testRealSingboxChecksAndStartsBothCustomProtocols() throws {
        guard let executable = SingboxProcessManager.locateExecutable() else { throw XCTSkip("本机没有 sing-box") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SingboxProcessManager(executableURL: executable, stateDirectory: root)
        defer { manager.stopAll() }
        for kind in ProxyKind.allCases {
            let json = try CustomOutbound.encoded([
                "type": .string(kind == .socks5 ? "socks" : "http"),
                "server": .string("192.0.2.1"), "server_port": .number(8080),
            ])
            let normalized = try CustomOutbound.checked(json, executableURL: executable)
            let id = UUID()
            try manager.start(profileID: id, outboundJSON: normalized)
            XCTAssertGreaterThan(try manager.waitUntilReady(profileID: id), 0)
            try manager.stop(profileID: id)
            XCTAssertFalse(manager.isRunning(profileID: id))
        }
        let bad = #"{"type":"http","server":"192.0.2.1","server_port":8080,"invalid_option":true}"#
        XCTAssertThrowsError(try CustomOutbound.checked(bad, executableURL: executable))
    }
}
