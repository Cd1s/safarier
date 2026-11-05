import Foundation
import Network
import Darwin

public enum ProxyTransportError: Error, Equatable {
    case invalidEndpoint, malformedPacket, fragmentedPacket, authentication, rejected, closed, timeout, unsupportedUDP, capacity
}

public struct ProxyEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) throws {
        guard !host.isEmpty, host.utf8.count <= 255,
              !host.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" || $0 == "/" }) else {
            throw ProxyTransportError.invalidEndpoint
        }
        self.host = host; self.port = port
    }
    public init(_ endpoint: NWEndpoint) throws {
        guard case let .hostPort(host, port) = endpoint else { throw ProxyTransportError.invalidEndpoint }
        try self.init(host: "\(host)", port: port.rawValue)
    }
    public var networkEndpoint: NWEndpoint { .hostPort(host: .init(host), port: .init(rawValue: port)!) }
    public var isUnspecified: Bool { host == "0.0.0.0" || host == "::" }
    public var isIP: Bool { IPv4Address(host) != nil || IPv6Address(host) != nil }
    public func matches(host: String, port: UInt16) -> Bool {
        guard self.port == port else { return false }
        if let a = IPv4Address(self.host), let b = IPv4Address(host) { return a.rawValue == b.rawValue }
        if let a = IPv6Address(self.host), let b = IPv6Address(host) { return a.rawValue == b.rawValue }
        return self.host.lowercased() == host.lowercased()
    }
    public var socksAddress: Data {
        var data = Data()
        if let address = IPv4Address(host) { data.append(1); data.append(address.rawValue) }
        else if let address = IPv6Address(host) { data.append(4); data.append(address.rawValue) }
        else { data.append(3); data.append(UInt8(host.utf8.count)); data.append(contentsOf: host.utf8) }
        data.append(UInt8(port >> 8)); data.append(UInt8(port & 255))
        return data
    }
    public static func decode(_ data: Data, offset: inout Int) throws -> Self {
        let bytes = [UInt8](data)
        func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= bytes.count else { throw ProxyTransportError.malformedPacket }
            defer { offset += count }; return Array(bytes[offset..<(offset + count)])
        }
        let type = try take(1)[0]
        let host: String
        switch type {
        case 1: host = IPv4Address(Data(try take(4)))!.debugDescription
        case 4: host = IPv6Address(Data(try take(16)))!.debugDescription
        case 3:
            let count = Int(try take(1)[0])
            guard count > 0, let value = String(bytes: try take(count), encoding: .utf8) else { throw ProxyTransportError.malformedPacket }
            host = value
        default: throw ProxyTransportError.malformedPacket
        }
        let port = try take(2)
        return try Self(host: host, port: UInt16(port[0]) << 8 | UInt16(port[1]))
    }
}

public enum SOCKS5Datagram {
    public static let maximumPayload = 65_000
    public static func encode(_ payload: Data, destination: ProxyEndpoint) throws -> Data {
        guard payload.count <= maximumPayload, destination.port != 0 else { throw ProxyTransportError.malformedPacket }
        return Data([0, 0, 0]) + destination.socksAddress + payload
    }
    public static func decode(_ packet: Data) throws -> (payload: Data, source: ProxyEndpoint) {
        let packet = Data(packet)
        guard packet.count >= 4, packet[0] == 0, packet[1] == 0 else { throw ProxyTransportError.malformedPacket }
        guard packet[2] == 0 else { throw ProxyTransportError.fragmentedPacket }
        var offset = 3
        let endpoint = try ProxyEndpoint.decode(packet, offset: &offset)
        guard endpoint.port != 0, packet.count - offset <= maximumPayload else { throw ProxyTransportError.malformedPacket }
        return (packet.subdata(in: offset..<packet.count), endpoint)
    }
}
