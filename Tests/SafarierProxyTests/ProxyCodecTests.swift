import XCTest
import SafarierCore
@testable import SafarierProxyTransport
@testable import SafarierProxyControl

final class ProxyCodecTests: XCTestCase {
    func testDatagramAddressFamiliesAndSourcePreservation() throws {
        for host in ["192.0.2.9", "2001:db8::9", "stun.example.invalid"] {
            let endpoint = try ProxyEndpoint(host: host, port: 3478)
            let packet = try SOCKS5Datagram.encode(Data([1, 2, 3]), destination: endpoint)
            let decoded = try SOCKS5Datagram.decode(packet)
            XCTAssertEqual(decoded.payload, Data([1, 2, 3]))
            XCTAssertTrue(decoded.source.matches(host: host, port: 3478))
            for length in 0..<(packet.count - 3) { XCTAssertThrowsError(try SOCKS5Datagram.decode(packet.prefix(length))) }
        }
    }
    func testRejectsFragmentationReservedBytesAndOversize() throws {
        let endpoint = try ProxyEndpoint(host: "192.0.2.1", port: 3478)
        var packet = try SOCKS5Datagram.encode(Data(), destination: endpoint)
        packet[2] = 1
        XCTAssertThrowsError(try SOCKS5Datagram.decode(packet)) { XCTAssertEqual($0 as? ProxyTransportError, .fragmentedPacket) }
        packet[2] = 0; packet[0] = 1
        XCTAssertThrowsError(try SOCKS5Datagram.decode(packet))
        XCTAssertThrowsError(try SOCKS5Datagram.encode(Data(count: 65_001), destination: endpoint))
        XCTAssertThrowsError(try SOCKS5Datagram.encode(Data(), destination: ProxyEndpoint(host: "192.0.2.1", port: 0)))
    }
    func testAuditTokenIsolationRevocationAndCapacity() throws {
        let table = ProxyRouteTable(capacity: 2)
        let one = Data(repeating: 1, count: 32), two = Data(repeating: 2, count: 32)
        let routeA = try ProxyRoute(proxy: ProxySettings(name: "a", kind: .socks5, host: "192.0.2.1", port: 1080), credentialSecret: nil)
        let routeB = try ProxyRoute(proxy: ProxySettings(name: "b", kind: .socks5, host: "192.0.2.2", port: 1081), credentialSecret: nil)
        try table.register(ProxyRegistration(token: one, profileID: UUID(), route: routeA))
        try table.register(ProxyRegistration(token: two, profileID: UUID(), route: routeB))
        if case .route(let value) = table.decision(token: one) { XCTAssertEqual(value.proxy.host, "192.0.2.1") } else { XCTFail() }
        if case .route(let value) = table.decision(token: two) { XCTAssertEqual(value.proxy.host, "192.0.2.2") } else { XCTFail() }
        table.revoke(one)
        if case .reject = table.decision(token: one) {} else { XCTFail() }
        XCTAssertThrowsError(try table.register(ProxyRegistration(token: one, profileID: UUID(), route: routeA)))
        XCTAssertThrowsError(try table.register(ProxyRegistration(token: Data(repeating: 3, count: 32), profileID: UUID(), route: routeA)))
        if case .pass = table.decision(token: Data(repeating: 3, count: 32)) {} else { XCTFail() }
        if case .pass = table.decision(token: nil) {} else { XCTFail() }
        table.revokeAll()
        if case .reject = table.decision(token: two) {} else { XCTFail() }
        if case .reject = table.decision(token: one) {} else { XCTFail() }
    }
    func testHostComparisonAndRegistrationValidation() throws {
        XCTAssertTrue(try ProxyEndpoint(host: "2001:db8::1", port: 1080).matches(host: "2001:0db8:0:0:0:0:0:1", port: 1080))
        XCTAssertFalse(try ProxyEndpoint(host: "192.0.2.1", port: 1080).matches(host: "192.0.2.2", port: 1080))
        XCTAssertThrowsError(try ProxyRegistration.decode(Data(count: 16_385)))
        XCTAssertThrowsError(try ProxyExtensionIdentity.requirement(team: "x\" or true", extensionProcess: true))
        let proxy = ProxySettings(name: "x", kind: .socks5, host: "192.0.2.1", port: 1080, username: "u")
        XCTAssertThrowsError(try ProxyRoute(proxy: proxy, credentialSecret: nil))
        XCTAssertThrowsError(try ProxyRoute(proxy: proxy, credentialSecret: String(repeating: "密", count: 100)))
    }
}
