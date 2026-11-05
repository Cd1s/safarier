import XCTest
import Network
import SafarierCore
@testable import SafarierProxyTransport

final class ProxyTransportTests: XCTestCase {
    func testAuthenticatedUDPUsesRelayPreservesTargetsAndDiesWithControl() async throws {
        let fixture = try LoopbackProxy(auth: true, wildcard: true)
        defer { fixture.close() }
        let port = try await fixture.start()
        let route = try ProxyRoute(proxy: ProxySettings(name: "test", kind: .socks5, host: "127.0.0.1", port: Int(port), username: "alice"), credentialSecret: "fixture-secret")
        let association = try SOCKS5Association(route: route)
        defer { association.close() }
        try await association.start()
        for target in [try ProxyEndpoint(host: "192.0.2.9", port: 3478), try ProxyEndpoint(host: "2001:db8::2", port: 49152)] {
            let payload = Data("media-\(target.port)".utf8)
            try await association.send(payload, to: target)
            let reply = try await association.receive()
            XCTAssertEqual(reply.source, target)
            XCTAssertEqual(reply.payload, payload)
        }
        XCTAssertEqual(fixture.snapshot().datagrams, 2)
        XCTAssertEqual(fixture.snapshot().auth, Data("alice:fixture-secret".utf8))
        XCTAssertEqual(fixture.snapshot().request, Data([5, 3, 0, 1, 0, 0, 0, 0, 0, 0]))
        fixture.closeControls()
        do { _ = try await association.receive(); XCTFail("control EOF must close pending UDP read") }
        catch { }
        do { try await association.send(Data([1]), to: ProxyEndpoint(host: "192.0.2.9", port: 3478)); XCTFail("closed association") }
        catch { }
    }

    func testMalformedRelayPacketClosesAssociation() async throws {
        let fixture = try LoopbackProxy(fragment: true)
        defer { fixture.close() }
        let port = try await fixture.start()
        let route = try ProxyRoute(proxy: ProxySettings(name: "test", kind: .socks5, host: "127.0.0.1", port: Int(port)), credentialSecret: nil)
        let association = try SOCKS5Association(route: route)
        defer { association.close() }
        try await association.start()
        try await association.send(Data([1]), to: ProxyEndpoint(host: "192.0.2.9", port: 3478))
        do { _ = try await association.receive(); XCTFail("FRAG must be rejected") }
        catch { XCTAssertEqual(error as? ProxyTransportError, .fragmentedPacket) }
        do { _ = try await association.receive(); XCTFail("association must remain closed") }
        catch { }
    }

    func testRejectedAuthenticationDoesNotIssueAssociate() async throws {
        let fixture = try LoopbackProxy(auth: true, rejectAuth: true)
        defer { fixture.close() }
        let port = try await fixture.start()
        let route = try ProxyRoute(proxy: ProxySettings(name: "test", kind: .socks5, host: "127.0.0.1", port: Int(port), username: "alice"), credentialSecret: "wrong")
        let association = try SOCKS5Association(route: route)
        defer { association.close() }
        do { try await association.start(); XCTFail("authentication must fail") }
        catch { XCTAssertEqual(error as? ProxyTransportError, .authentication) }
        XCTAssertNil(fixture.snapshot().request)
        XCTAssertEqual(fixture.snapshot().datagrams, 0)
    }

    func testSilentProxyHandshakeExpiresWithoutWaitingForServerEOF() async throws {
        let fixture = try LoopbackProxy(holdHandshake: true)
        defer { fixture.close() }
        let port = try await fixture.start()
        let route = try ProxyRoute(proxy: ProxySettings(name: "test", kind: .socks5, host: "127.0.0.1", port: Int(port)), credentialSecret: nil)
        let association = try SOCKS5Association(route: route)
        defer { association.close() }
        let start = Date()
        do { try await association.start(); XCTFail("silent handshake must expire") }
        catch { }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 9)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
        XCTAssertEqual(fixture.snapshot().datagrams, 0)
    }

    func testHTTPUDPRefusedBeforeOpeningControlConnection() async throws {
        let fixture = try LoopbackProxy(http: true)
        defer { fixture.close() }
        let port = try await fixture.start()
        let route = try ProxyRoute(proxy: ProxySettings(name: "test", kind: .httpConnect, host: "127.0.0.1", port: Int(port)), credentialSecret: nil)
        let association = try SOCKS5Association(route: route)
        defer { association.close() }
        do { try await association.start(); XCTFail("HTTP CONNECT has no UDP association") }
        catch { XCTAssertEqual(error as? ProxyTransportError, .unsupportedUDP) }
        XCTAssertEqual(fixture.snapshot().connections, 0)
        XCTAssertEqual(fixture.snapshot().datagrams, 0)
    }

    func testTCPAndHTTPPreserveReverseDataAfterLocalHalfClose() async throws {
        for http in [false, true] {
            let fixture = try LoopbackProxy(http: http)
            defer { fixture.close() }
            let port = try await fixture.start()
            let route = try ProxyRoute(proxy: ProxySettings(name: "test", kind: http ? .httpConnect : .socks5, host: "127.0.0.1", port: Int(port)), credentialSecret: nil)
            let socket = ProxySocket(endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!))
            defer { socket.close() }
            _ = try await ProxyHandshake.connect(route: route, destination: ProxyEndpoint(host: "example.invalid", port: 443), socket: socket)
            try await socket.write(Data("hello".utf8))
            try await socket.write(nil, final: true)
            let reply = try await socket.readExactly(5)
            XCTAssertEqual(reply, Data("hello".utf8))
            let eof = try await socket.read()
            XCTAssertNil(eof)
            if http { XCTAssertTrue(String(data: fixture.snapshot().request!, encoding: .utf8)!.hasPrefix("CONNECT example.invalid:443 HTTP/1.1\r\n")) }
        }
    }
}

/// External server fixture only; all client handshakes, codecs and lifecycle are production code.
private final class LoopbackProxy: @unchecked Sendable {
    struct Snapshot { var request: Data?; var auth: Data?; var datagrams = 0; var connections = 0 }
    private let queue = DispatchQueue(label: "test.proxy.fixture")
    private let tcp: NWListener
    private let udp: NWListener
    private var controls: [NWConnection] = []
    private var relays: [NWConnection] = []
    private var state = Snapshot()
    private let auth: Bool, rejectAuth: Bool, wildcard: Bool, fragment: Bool, http: Bool, holdHandshake: Bool
    init(auth: Bool = false, rejectAuth: Bool = false, wildcard: Bool = false, fragment: Bool = false, http: Bool = false, holdHandshake: Bool = false) throws {
        self.auth = auth; self.rejectAuth = rejectAuth; self.wildcard = wildcard; self.fragment = fragment; self.http = http; self.holdHandshake = holdHandshake
        let tcpParameters = NWParameters.tcp, udpParameters = NWParameters.udp
        tcpParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        udpParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        tcp = try NWListener(using: tcpParameters); udp = try NWListener(using: udpParameters)
    }
    func snapshot() -> Snapshot { queue.sync { state } }
    func start() async throws -> UInt16 {
        tcp.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.state.connections += 1; self.controls.append(connection); connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + (self.holdHandshake ? 30 : 10)) { connection.cancel() }
            Task { do { try await self.serve(connection) } catch { connection.cancel() } }
        }
        udp.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.relays.append(connection); connection.start(queue: self.queue); self.echo(connection)
            self.queue.asyncAfter(deadline: .now() + (self.holdHandshake ? 30 : 10)) { connection.cancel() }
        }
        _ = try await ready(udp)
        return try await ready(tcp)
    }
    private func ready(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    private func serve(_ c: NWConnection) async throws {
        if holdHandshake { return }
        if http {
            var request = Data()
            while !request.suffix(4).elementsEqual([13,10,13,10]), request.count < 16_384 { request += try await read(c, 1) }
            let saved = request; queue.sync { state.request = saved }
            try await write(c, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        } else {
            let greeting = try await read(c, 3)
            guard greeting == Data([5, 1, auth ? 2 : 0]) else { throw ProxyTransportError.authentication }
            try await write(c, Data([5, auth ? 2 : 0]))
            if auth {
                let head = try await read(c, 2)
                let user = try await read(c, Int(head[1]))
                let length = try await read(c, 1)[0]
                let secret = try await read(c, Int(length))
                queue.sync { state.auth = user + Data([58]) + secret }
                try await write(c, Data([1, rejectAuth ? 1 : 0]))
                if rejectAuth { c.cancel(); return }
            }
            let head = try await read(c, 4)
            var request = head
            if head[3] == 1 { request += try await read(c, 6) }
            else if head[3] == 4 { request += try await read(c, 18) }
            else { let n = try await read(c, 1)[0]; request.append(n); request += try await read(c, Int(n) + 2) }
            let saved = request; queue.sync { state.request = saved }
            let port = queue.sync { udp.port!.rawValue }
            let address: [UInt8] = wildcard ? [0,0,0,0] : [127,0,0,1]
            try await write(c, Data([5,0,0,1] + address + [UInt8(port >> 8), UInt8(port & 255)]))
            if head[1] == 3 { return } // Retain TCP until the test explicitly closes it.
        }
        // Delay the reply until the client has sent FIN: catches premature bidirectional teardown.
        let payload = try await read(c, 5)
        let eof: Data? = try await withCheckedThrowingContinuation { continuation in
            c.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
            }
        }
        guard eof == nil || eof!.isEmpty else { throw ProxyTransportError.malformedPacket }
        try await write(c, payload)
        try await write(c, nil, final: true)
    }
    private func echo(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, var data, error == nil else { return }
            self.state.datagrams += 1
            if self.fragment, data.count > 2 { data[2] = 1 }
            c.send(content: data, completion: .contentProcessed { _ in self.echo(c) })
        }
    }
    func closeControls() { queue.sync { controls.forEach { $0.cancel() }; controls.removeAll() } }
    func close() { queue.sync { tcp.cancel(); udp.cancel(); controls.forEach { $0.cancel() }; relays.forEach { $0.cancel() }; controls.removeAll(); relays.removeAll() } }
    private func read(_ c: NWConnection, _ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let maximum = count - result.count
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                c.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                    if let data, !data.isEmpty, error == nil { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: ProxyTransportError.closed) }
                }
            }
            result += data
        }
        return result
    }
    private func write(_ c: NWConnection, _ data: Data?, final: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            c.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
