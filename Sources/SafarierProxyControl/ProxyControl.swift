import Foundation
import Security
import Darwin
import SafarierCore
import SafarierProxyTransport

public enum ProxyControlError: Error { case unavailable, invalidIdentity, invalidRequest, duplicate, capacity, notReady }

public enum ProxyExtensionIdentity {
    public static let hostID = "sh.safarier.app"
    public static let extensionID = "sh.safarier.app.network-extension"
    public static func team(in bundle: Bundle = .main) throws -> String {
        guard let value = bundle.object(forInfoDictionaryKey: "SafarierTeamIdentifier") as? String,
              value.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw ProxyControlError.invalidIdentity }
        return value
    }
    public static func service(team: String) -> String { "\(team).sh.safarier.proxy.control" }
    public static func requirement(team: String, extensionProcess: Bool) throws -> String {
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw ProxyControlError.invalidIdentity }
        let identifier = extensionProcess ? extensionID : hostID
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }
    public static func ownAuditToken() throws -> Data {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw ProxyControlError.invalidIdentity }
        return withUnsafeBytes(of: token) { Data($0) }
    }
    /// Validation is of live code identified by the whole token, never just the on-disk executable.
    public static func validate(token: Data, connection: NSXPCConnection, requirement: String) throws {
        guard token.count == 32 else { throw ProxyControlError.invalidIdentity }
        let words: [UInt32] = token.withUnsafeBytes { bytes in
            (0..<8).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
        }
        guard words[5] == UInt32(bitPattern: connection.processIdentifier), words[1] == connection.effectiveUserIdentifier else {
            throw ProxyControlError.invalidIdentity
        }
        var code: SecCode?, rule: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
              let rule,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: token] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], rule) == errSecSuccess else { throw ProxyControlError.invalidIdentity }
    }
}

public struct ProxyRegistration: Codable {
    public let token: Data
    public let profileID: UUID
    public let route: ProxyRoute
    public init(token: Data, profileID: UUID, route: ProxyRoute) { self.token = token; self.profileID = profileID; self.route = route }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384 else { throw ProxyControlError.invalidRequest }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.token.count == 32 else { throw ProxyControlError.invalidRequest }
        _ = try value.route.validated()
        return value
    }
}

@objc public protocol ProxyControlProtocol {
    func register(_ payload: Data, reply: @escaping (Bool) -> Void)
}

/// Caller serializes access. Revoked tokens are retained; no eviction can re-enable direct traffic.
public final class ProxyRouteTable {
    public enum Decision { case pass, reject, route(ProxyRoute) }
    private var routes: [Data: ProxyRoute] = [:]
    private var retired: Set<Data> = []
    public let capacity: Int
    public init(capacity: Int = 256) { self.capacity = capacity }
    public func register(_ value: ProxyRegistration) throws {
        guard value.token.count == 32 else { throw ProxyControlError.invalidRequest }
        guard routes[value.token] == nil, !retired.contains(value.token) else { throw ProxyControlError.duplicate }
        guard routes.count + retired.count < capacity else { throw ProxyControlError.capacity }
        routes[value.token] = try value.route.validated()
    }
    public func revoke(_ token: Data) {
        if routes.removeValue(forKey: token) != nil { retired.insert(token) }
    }
    public func revokeAll() {
        retired.formUnion(routes.keys); routes.removeAll()
    }
    public func decision(token: Data?) -> Decision {
        guard let token, token.count == 32 else { return .pass }
        if retired.contains(token) { return .reject }
        if let route = routes[token] { return .route(route) }
        return .pass
    }
}

/// Kept for the entire Runner lifetime. No reconnection: a lost route invalidates this browsing session.
public final class ProxyExtensionClient {
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var valid = false
    private var cancelled = false
    public var isReady: Bool { lock.lock(); defer { lock.unlock() }; return valid && !cancelled }
    public init(profileID: UUID, route: ProxyRoute, onLoss: @escaping () -> Void) throws {
        let team = try ProxyExtensionIdentity.team()
        connection = NSXPCConnection(machServiceName: ProxyExtensionIdentity.service(team: team), options: .privileged)
        connection.setCodeSigningRequirement(try ProxyExtensionIdentity.requirement(team: team, extensionProcess: true))
        connection.remoteObjectInterface = NSXPCInterface(with: ProxyControlProtocol.self)
        connection.invalidationHandler = { [weak self] in self?.lost(onLoss) }
        connection.interruptionHandler = { [weak self] in self?.lost(onLoss) }
        let payload = try JSONEncoder().encode(ProxyRegistration(token: ProxyExtensionIdentity.ownAuditToken(), profileID: profileID, route: route))
        guard payload.count <= 16_384 else { connection.invalidate(); throw ProxyControlError.invalidRequest }
        connection.resume()
        let completion = RegistrationReply()
        let service = connection.remoteObjectProxyWithErrorHandler { _ in completion.finish(false) } as? ProxyControlProtocol
        service?.register(payload) { completion.finish($0) }
        guard completion.wait(), markReady() else { close(); throw ProxyControlError.unavailable }
    }
    private func markReady() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }; valid = true; return true
    }
    private func lost(_ action: () -> Void) {
        lock.lock(); let notify = valid && !cancelled; valid = false; cancelled = true; lock.unlock()
        if notify { action() }
    }
    public func close() {
        lock.lock(); valid = false; cancelled = true; lock.unlock()
        connection.invalidate()
    }
    deinit { close() }
}

private final class RegistrationReply {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Bool?
    func finish(_ result: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard self.result == nil else { return }; self.result = result; semaphore.signal()
    }
    func wait() -> Bool {
        guard semaphore.wait(timeout: .now() + 10) == .success else { return false }
        lock.lock(); defer { lock.unlock() }; return result == true
    }
}
