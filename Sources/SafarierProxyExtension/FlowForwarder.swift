import Foundation
import Network
import NetworkExtension
import SafarierProxyTransport

@available(macOS 15.0, *)
final class FlowForwarder: @unchecked Sendable {
    let id = UUID()
    let token: Data
    private let flow: NEAppProxyFlow
    private let lock = NSLock()
    private var closed = false
    private var completedDirections = 0
    private var tasks: [Task<Void, Never>] = []
    private var socket: ProxySocket?
    private var association: SOCKS5Association?
    private let onClose: (UUID) -> Void
    init(flow: NEAppProxyFlow, token: Data, onClose: @escaping (UUID) -> Void) {
        self.flow = flow; self.token = token; self.onClose = onClose
    }
    func start(route: ProxyRoute) {
        add(Task { [self] in
            do {
                if let udp = flow as? NEAppProxyUDPFlow {
                    guard route.proxy.kind == .socks5 else { throw ProxyTransportError.unsupportedUDP }
                    let association = try SOCKS5Association(route: route)
                    guard install(association: association) else { association.close(); return }
                    try await association.start()
                    try Task.checkCancellation()
                    try await udp.open(withLocalFlowEndpoint: nil)
                    add(Task { [self] in
                        do {
                            while !Task.isCancelled {
                                let (batch, error) = await udp.readDatagrams()
                                if error != nil { throw ProxyTransportError.closed }
                                guard let batch, !batch.isEmpty else { close(); return }
                                guard batch.count <= 64, batch.reduce(0, { $0 + $1.0.count }) <= 1_048_576 else { throw ProxyTransportError.capacity }
                                for (payload, destination) in batch {
                                    try Task.checkCancellation()
                                    try await association.send(payload, to: ProxyEndpoint(destination))
                                }
                            }
                        } catch { close() }
                    })
                    add(Task { [self] in
                        do {
                            while !Task.isCancelled {
                                let packet = try await association.receive()
                                try Task.checkCancellation()
                                try await udp.writeDatagrams([(packet.payload, packet.source.networkEndpoint)])
                            }
                        } catch { close() }
                    })
                } else if let tcp = flow as? NEAppProxyTCPFlow {
                    let destination = try ProxyEndpoint(tcp.remoteFlowEndpoint)
                    guard destination.port != 0 else { throw ProxyTransportError.invalidEndpoint }
                    let socket = ProxySocket(endpoint: .hostPort(host: .init(route.proxy.host), port: .init(rawValue: UInt16(route.proxy.port))!))
                    guard install(socket: socket) else { socket.close(); return }
                    _ = try await ProxyHandshake.connect(route: route, destination: destination, socket: socket)
                    try Task.checkCancellation()
                    try await tcp.open(withLocalFlowEndpoint: nil)
                    add(Task { [self] in
                        do {
                            while !Task.isCancelled {
                                let data: Data = try await withCheckedThrowingContinuation { continuation in
                                    tcp.readData { data, error in
                                        if let error { continuation.resume(throwing: error) }
                                        else { continuation.resume(returning: data ?? Data()) }
                                    }
                                }
                                guard !data.isEmpty else {
                                    try await socket.write(nil, final: true); completedDirection(); return
                                }
                                guard data.count <= 1_048_576 else { throw ProxyTransportError.capacity }
                                try await socket.write(data)
                            }
                        } catch { close() }
                    })
                    add(Task { [self] in
                        do {
                            while !Task.isCancelled {
                                guard let data = try await socket.read() else {
                                    tcp.closeWriteWithError(nil); completedDirection(); return
                                }
                                try await tcp.write(data)
                            }
                        } catch { close() }
                    })
                } else { close() }
            } catch { close() }
        })
    }
    private func add(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if closed { task.cancel() } else { tasks.append(task) }
    }
    private func install(socket: ProxySocket? = nil, association: SOCKS5Association? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }; self.socket = socket; self.association = association; return true
    }
    private func completedDirection() {
        lock.lock(); completedDirections += 1; let done = completedDirections == 2; lock.unlock()
        if done { close(gracefully: true) }
    }
    func close(gracefully: Bool = false) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let tasks = self.tasks; self.tasks = []
        let socket = self.socket; self.socket = nil
        let association = self.association; self.association = nil
        lock.unlock()
        tasks.forEach { $0.cancel() }; socket?.close(); association?.close()
        if gracefully { flow.closeReadWithError(nil); flow.closeWriteWithError(nil) }
        else { Self.reject(flow) }
        onClose(id)
    }
    static func reject(_ flow: NEAppProxyFlow) {
        let error = NSError(domain: "sh.safarier.proxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "代理流已关闭"])
        flow.closeReadWithError(error); flow.closeWriteWithError(error)
    }
}
