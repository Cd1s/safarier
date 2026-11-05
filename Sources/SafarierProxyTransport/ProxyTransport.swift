import Foundation
import Network
import SafarierCore

/// Credentials live only in the owning connection. Never interpolate this value into diagnostics.
public struct ProxyRoute: Codable, Sendable {
    public let proxy: ProxySettings
    public let credentialSecret: String?
    public init(proxy: ProxySettings, credentialSecret: String?) throws {
        try proxy.validate()
        _ = try ProxyEndpoint(host: proxy.host, port: UInt16(proxy.port))
        if let user = proxy.username, !user.isEmpty {
            guard user.utf8.count <= 255, let credentialSecret, !credentialSecret.isEmpty, credentialSecret.utf8.count <= 255,
                  (proxy.kind != .httpConnect || !user.contains(":")), !user.contains("\0") else { throw ProxyTransportError.authentication }
        }
        self.proxy = proxy; self.credentialSecret = credentialSecret
    }
    public func validated() throws -> Self { try Self(proxy: proxy, credentialSecret: credentialSecret) }
}

/// Serial Network.framework operations, with cancellation that also completes pending reads.
public final class ProxySocket: @unchecked Sendable {
    public let connection: NWConnection
    private let queue = DispatchQueue(label: "sh.safarier.proxy.socket")
    public init(endpoint: NWEndpoint, udp: Bool = false) {
        connection = NWConnection(to: endpoint, using: udp ? .udp : .tcp)
    }
    public func start(timeout: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                var completed = false
                let timer = DispatchWorkItem { [weak self] in
                    guard !completed else { return }; completed = true
                    self?.connection.cancel(); continuation.resume(throwing: ProxyTransportError.timeout)
                }
                self.connection.stateUpdateHandler = { state in
                    guard !completed else { return }
                    switch state {
                    case .ready: completed = true; timer.cancel(); continuation.resume()
                    case .failed, .cancelled:
                        completed = true; timer.cancel(); continuation.resume(throwing: ProxyTransportError.closed)
                    default: break
                    }
                }
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                self.connection.start(queue: self.queue)
            }
        }
    }
    public func read(maximum: Int = 65_536) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                if error != nil { continuation.resume(throwing: ProxyTransportError.closed) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: nil) }
                else { continuation.resume(throwing: ProxyTransportError.closed) }
            }
        }
    }
    public func readExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            guard let part = try await read(maximum: count - result.count) else { throw ProxyTransportError.closed }
            result.append(part)
        }
        return result
    }
    public func write(_ data: Data?, final: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                            completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: ProxyTransportError.closed) }
                else { continuation.resume() }
            })
        }
    }
    public func receiveDatagram() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, _, _, error in
                if error != nil { continuation.resume(throwing: ProxyTransportError.closed) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: ProxyTransportError.closed) }
            }
        }
    }
    public func close() { connection.cancel() }
    deinit { close() }
}

public enum ProxyHandshake {
    public static func connect(route: ProxyRoute, destination: ProxyEndpoint, command: UInt8 = 1,
                               socket: ProxySocket) async throws -> ProxyEndpoint {
        let route = try route.validated()
        guard command == 1 || command == 3 else { throw ProxyTransportError.rejected }
        // Covers the entire handshake, not just establishing the TCP connection.
        let timeout = DispatchWorkItem { socket.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        do {
            try await socket.start()
            if route.proxy.kind == .httpConnect {
                guard command == 1 else { throw ProxyTransportError.unsupportedUDP }
                let host = destination.host.contains(":") ? "[\(destination.host)]" : destination.host
                let authority = "\(host):\(destination.port)"
                var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n"
                if let user = route.proxy.username, !user.isEmpty, let credentialSecret = route.credentialSecret {
                    let credential = Data("\(user):\(credentialSecret)".utf8).base64EncodedString()
                    request += "Proxy-Authorization: Basic \(credential)\r\n"
                }
                try await socket.write(Data((request + "\r\n").utf8))
                var response = Data()
                while response.count < 16_384 && !response.suffix(4).elementsEqual([13, 10, 13, 10]) {
                    response.append(try await socket.readExactly(1))
                }
                guard response.suffix(4).elementsEqual([13, 10, 13, 10]),
                      let line = String(data: response, encoding: .utf8)?.components(separatedBy: "\r\n").first else {
                    throw ProxyTransportError.rejected
                }
                let fields = line.split(separator: " ")
                guard fields.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(fields[0])),
                      let code = Int(fields[1]), (200..<300).contains(code) else { throw ProxyTransportError.rejected }
                return destination
            }
            let authentication = route.proxy.username?.isEmpty == false
            try await socket.write(Data([5, 1, authentication ? 2 : 0]))
            let method = try await socket.readExactly(2)
            guard method == Data([5, authentication ? 2 : 0]) else { throw ProxyTransportError.authentication }
            if authentication {
                let user = Data(route.proxy.username!.utf8), credentialSecret = Data(route.credentialSecret!.utf8)
                try await socket.write(Data([1, UInt8(user.count)]) + user + Data([UInt8(credentialSecret.count)]) + credentialSecret)
                guard try await socket.readExactly(2) == Data([1, 0]) else { throw ProxyTransportError.authentication }
            }
            try await socket.write(Data([5, command, 0]) + destination.socksAddress)
            let head = try await socket.readExactly(4)
            guard head[0] == 5, head[1] == 0, head[2] == 0 else { throw ProxyTransportError.rejected }
            var address = Data([head[3]])
            switch head[3] {
            case 1: address.append(try await socket.readExactly(6))
            case 4: address.append(try await socket.readExactly(18))
            case 3:
                let count = try await socket.readExactly(1)[0]
                address.append(count); address.append(try await socket.readExactly(Int(count) + 2))
            default: throw ProxyTransportError.malformedPacket
            }
            var offset = 0
            return try ProxyEndpoint.decode(address, offset: &offset)
        } catch { socket.close(); throw error }
    }
}

public final class SOCKS5Association: @unchecked Sendable {
    public let control: ProxySocket
    private let lock = NSLock()
    private var relay: ProxySocket?
    private var closed = false
    private var started = false
    private var monitor: Task<Void, Never>?
    private let route: ProxyRoute
    public init(route: ProxyRoute) throws {
        self.route = try route.validated()
        control = ProxySocket(endpoint: .hostPort(host: .init(route.proxy.host), port: .init(rawValue: UInt16(route.proxy.port))!))
    }
    public func start() async throws {
        guard begin() else { throw ProxyTransportError.closed }
        guard route.proxy.kind == .socks5 else { throw ProxyTransportError.unsupportedUDP }
        do {
            var endpoint = try await ProxyHandshake.connect(route: route, destination: ProxyEndpoint(host: "0.0.0.0", port: 0), command: 3, socket: control)
            guard endpoint.port != 0 else { throw ProxyTransportError.invalidEndpoint }
            if endpoint.isUnspecified {
                guard let remote = control.connection.currentPath?.remoteEndpoint,
                      let peer = try? ProxyEndpoint(remote), peer.isIP else { throw ProxyTransportError.invalidEndpoint }
                endpoint = try ProxyEndpoint(host: peer.host, port: endpoint.port)
            }
            let relay = ProxySocket(endpoint: endpoint.networkEndpoint, udp: true)
            guard install(relay) else { relay.close(); throw ProxyTransportError.closed }
            try await relay.start()
            installMonitor()
        } catch { close(); throw error }
    }
    private func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !started else { return false }; started = true; return true
    }
    private func install(_ socket: ProxySocket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }; relay = socket; return true
    }
    private func installMonitor() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        monitor = Task { [weak self, control] in
            // No application data is defined on this control connection after ASSOCIATE.
            _ = try? await control.read()
            self?.close()
        }
    }
    private func currentRelay() throws -> ProxySocket {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let relay else { throw ProxyTransportError.closed }; return relay
    }
    public func send(_ payload: Data, to destination: ProxyEndpoint) async throws {
        try await currentRelay().write(SOCKS5Datagram.encode(payload, destination: destination))
    }
    public func receive() async throws -> (payload: Data, source: ProxyEndpoint) {
        do { return try SOCKS5Datagram.decode(await currentRelay().receiveDatagram()) }
        catch { close(); throw error }
    }
    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true; let relay = self.relay; self.relay = nil
        let monitor = self.monitor; self.monitor = nil
        lock.unlock()
        control.close(); relay?.close(); monitor?.cancel()
    }
    deinit { close() }
}
