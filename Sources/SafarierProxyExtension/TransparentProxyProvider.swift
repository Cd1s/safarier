import Foundation
import Network
import NetworkExtension
import SafarierProxyTransport
import SafarierProxyControl

@available(macOS 15.0, *)
@objc(SafarierTransparentProxyProvider)
final class TransparentProxyProvider: NETransparentProxyProvider, NEAppProxyUDPFlowHandling, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: "sh.safarier.proxy.provider")
    private var ready = false
    private var stopping = false
    private var routes = ProxyRouteTable()
    private var listener: NSXPCListener?
    private var clients: [UUID: Client] = [:]
    private var flows: [UUID: FlowForwarder] = [:]
    private var requirement = ""
    private struct Client { let connection: NSXPCConnection; var token: Data? }

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        do {
            let team = try ProxyExtensionIdentity.team()
            requirement = try ProxyExtensionIdentity.requirement(team: team, extensionProcess: false)
            let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
            settings.includedNetworkRules = [
                NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .outbound),
                NENetworkRule(destinationNetworkEndpoint: .hostPort(host: "127.0.0.1", port: .any), prefix: 32, protocol: .any),
                NENetworkRule(destinationNetworkEndpoint: .hostPort(host: "::1", port: .any), prefix: 128, protocol: .any),
            ]
            setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self else { completionHandler(ProxyControlError.notReady); return }
                self.queue.async {
                    guard error == nil, !self.stopping else { completionHandler(error ?? ProxyControlError.notReady); return }
                    let listener = NSXPCListener(machServiceName: ProxyExtensionIdentity.service(team: team))
                    listener.delegate = self
                    self.listener = listener; self.ready = true
                    listener.resume()
                    completionHandler(nil)
                }
            }
        } catch { completionHandler(ProxyControlError.invalidIdentity) }
    }
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.stopping = true; self.ready = false
            self.listener?.invalidate(); self.listener = nil
            self.clients.values.forEach { $0.connection.invalidate() }; self.clients.removeAll()
            self.flows.values.forEach { $0.close() }; self.flows.removeAll()
            self.routes.revokeAll()
            completionHandler()
        }
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        queue.sync {
            guard ready, clients.count < 256 else { return false }
            let owner = UUID()
            connection.setCodeSigningRequirement(requirement)
            connection.exportedInterface = NSXPCInterface(with: ProxyControlProtocol.self)
            connection.exportedObject = RegistrationService(provider: self, owner: owner, connection: connection)
            connection.invalidationHandler = { [weak self] in self?.revoke(owner) }
            connection.interruptionHandler = { [weak self] in self?.revoke(owner) }
            clients[owner] = Client(connection: connection, token: nil)
            connection.resume()
            return true
        }
    }
    fileprivate func register(_ payload: Data, owner: UUID, connection: NSXPCConnection, reply: @escaping (Bool) -> Void) {
        do {
            let request = try ProxyRegistration.decode(payload)
            try ProxyExtensionIdentity.validate(token: request.token, connection: connection, requirement: requirement)
            queue.async {
                guard self.ready, var client = self.clients[owner], client.token == nil else { reply(false); return }
                do {
                    try self.routes.register(request)
                    client.token = request.token; self.clients[owner] = client
                    reply(true)
                } catch { reply(false) }
            }
        } catch { reply(false) }
    }
    private func revoke(_ owner: UUID) {
        queue.async {
            guard let client = self.clients.removeValue(forKey: owner) else { return }
            client.connection.invalidate()
            guard let token = client.token else { return }
            self.routes.revoke(token)
            self.flows.values.filter { $0.token == token }.forEach { $0.close() }
        }
    }
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool { handle(flow) }
    func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint) -> Bool { handle(flow) }
    private func handle(_ flow: NEAppProxyFlow) -> Bool {
        queue.sync {
            // Never infer ownership from a bundle name or a recycled PID. Missing attribution is a release blocker.
            switch routes.decision(token: flow.metaData.sourceAppAuditToken) {
            case .pass: return false
            case .reject: FlowForwarder.reject(flow); return true
            case .route(let route):
                guard ready, let token = flow.metaData.sourceAppAuditToken,
                      flows.count < 1024, flows.values.filter({ $0.token == token }).count < 128 else {
                    FlowForwarder.reject(flow); return true
                }
                if let tcp = flow as? NEAppProxyTCPFlow, let endpoint = try? ProxyEndpoint(tcp.remoteFlowEndpoint),
                   let upstream = try? ProxyEndpoint(host: route.proxy.host, port: UInt16(route.proxy.port)),
                   upstream.matches(host: flow.remoteHostname ?? endpoint.host, port: endpoint.port) {
                    return false // The original WK proxy connection must not be nested through itself.
                }
                let forwarder = FlowForwarder(flow: flow, token: token) { [weak self] id in
                    self?.queue.async { self?.flows.removeValue(forKey: id) }
                }
                flows[forwarder.id] = forwarder
                forwarder.start(route: route)
                return true // All errors after this point close both sides, never return to the direct path.
            }
        }
    }
}

@available(macOS 15.0, *)
private final class RegistrationService: NSObject, ProxyControlProtocol {
    weak var provider: TransparentProxyProvider?
    weak var connection: NSXPCConnection?
    let owner: UUID
    init(provider: TransparentProxyProvider, owner: UUID, connection: NSXPCConnection) {
        self.provider = provider; self.owner = owner; self.connection = connection
    }
    func register(_ payload: Data, reply: @escaping (Bool) -> Void) {
        guard let provider, let connection else { reply(false); return }
        provider.register(payload, owner: owner, connection: connection, reply: reply)
    }
}
