import XCTest
@testable import SafarierNetwork

final class LocalNetworkInterfaceResolverTests: XCTestCase {
    func testPrefersPhysicalInterfaceOverClashUTUNWhenPrimaryIsTunnel() throws {
        let snapshot = NetworkStateSnapshot(
            primaryInterface: "utun1024",
            primaryServiceID: "clash-tun",
            serviceOrder: ["clash-tun", "wifi-service"],
            services: [
                NetworkServiceState(
                    id: "clash-tun",
                    interfaceName: "utun1024",
                    ipv4Addresses: ["198.18.0.1"],
                    router: nil,
                    dnsServers: ["198.18.0.2"]
                ),
                NetworkServiceState(
                    id: "wifi-service",
                    interfaceName: "en0",
                    ipv4Addresses: ["192.0.2.25"],
                    router: "192.0.2.1",
                    dnsServers: ["198.51.100.53"]
                ),
            ]
        )

        let target = try LocalNetworkInterfaceResolver.resolve(from: snapshot)
        XCTAssertEqual(target.interfaceName, "en0")
        XCTAssertEqual(target.dnsServers, ["198.51.100.53"])
    }

    func testFiltersFakeIPAndLoopbackDNSAndFallsBackToRouter() throws {
        let withMixedDNS = NetworkStateSnapshot(
            primaryInterface: "en0",
            primaryServiceID: "wifi",
            services: [
                NetworkServiceState(
                    id: "wifi",
                    interfaceName: "en0",
                    ipv4Addresses: ["198.51.100.50"],
                    router: "198.51.100.1",
                    dnsServers: ["2001:db8::53", "198.18.0.2", "127.0.0.1", "203.0.113.53", "203.0.113.53"]
                )
            ]
        )
        XCTAssertEqual(
            try LocalNetworkInterfaceResolver.resolve(from: withMixedDNS).dnsServers,
            ["203.0.113.53", "2001:db8::53"]
        )

        let fakeOnlyDNS = NetworkStateSnapshot(
            primaryInterface: "en0",
            primaryServiceID: "wifi",
            services: [
                NetworkServiceState(
                    id: "wifi",
                    interfaceName: "en0",
                    ipv4Addresses: ["192.0.2.25"],
                    router: "192.0.2.1",
                    dnsServers: ["198.18.0.2", "127.0.0.1"]
                )
            ]
        )
        XCTAssertEqual(try LocalNetworkInterfaceResolver.resolve(from: fakeOnlyDNS).dnsServers, ["192.0.2.1"])
    }

    func testFallsBackToPublicDirectDNSWhenBothDHCPAndRouterAreMissing() throws {
        let snapshot = NetworkStateSnapshot(
            services: [
                NetworkServiceState(
                    id: "usb-lan",
                    interfaceName: "en5",
                    ipv4Addresses: ["203.0.113.12"],
                    router: nil,
                    dnsServers: []
                )
            ]
        )
        let target = try LocalNetworkInterfaceResolver.resolve(from: snapshot)
        XCTAssertEqual(target.interfaceName, "en5")
        XCTAssertEqual(target.dnsServers, LocalNetworkInterfaceResolver.fallbackDirectDNSServers)
    }

    func testThrowsWhenOnlyVirtualOrLoopbackInterfacesExist() {
        let snapshot = NetworkStateSnapshot(
            primaryInterface: "utun1024",
            services: [
                NetworkServiceState(id: "lo", interfaceName: "lo0", ipv4Addresses: ["127.0.0.1"]),
                NetworkServiceState(id: "tun", interfaceName: "utun1024", ipv4Addresses: ["198.18.0.1"]),
                NetworkServiceState(id: "awdl", interfaceName: "awdl0", ipv4Addresses: ["169.254.1.2"]),
            ]
        )
        XCTAssertThrowsError(try LocalNetworkInterfaceResolver.resolve(from: snapshot)) { error in
            XCTAssertEqual(error as? LocalNetworkDirectError, .noPhysicalInterface)
        }
    }

    func testErrorDescriptionMatchesStringInterpolation() {
        XCTAssertTrue("\(LocalNetworkDirectError.noPhysicalInterface)".contains("找不到可用的本地物理网络"))
        XCTAssertTrue("\(LocalNetworkDirectError.invalidInterfaceName(" "))".contains("本地物理网络接口名无效"))
        XCTAssertTrue("\(LocalNetworkDirectError.noUsableDNSServer)".contains("找不到可用的本地 DNS 服务器"))
    }
}
