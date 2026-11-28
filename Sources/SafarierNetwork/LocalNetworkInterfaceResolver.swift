import Foundation
import Darwin
import SystemConfiguration
import SafarierCore

/// 解析出的本机物理网卡与直连 DNS 目标。
public struct LocalDirectNetworkTarget: Equatable, Sendable {
    public let interfaceName: String
    public let dnsServers: [String]

    public init(interfaceName: String, dnsServers: [String]) {
        self.interfaceName = interfaceName
        self.dnsServers = dnsServers
    }
}

/// 采集到的系统网络服务状态快照（纯数据结构，便于离线单测）。
public struct NetworkServiceState: Equatable, Sendable {
    public let id: String
    public let interfaceName: String
    public let ipv4Addresses: [String]
    public let router: String?
    public let dnsServers: [String]

    public init(
        id: String,
        interfaceName: String,
        ipv4Addresses: [String] = [],
        router: String? = nil,
        dnsServers: [String] = []
    ) {
        self.id = id
        self.interfaceName = interfaceName
        self.ipv4Addresses = ipv4Addresses
        self.router = router
        self.dnsServers = dnsServers
    }
}

public struct NetworkStateSnapshot: Equatable, Sendable {
    public let primaryInterface: String?
    public let primaryServiceID: String?
    public let serviceOrder: [String]
    public let services: [NetworkServiceState]

    public init(
        primaryInterface: String? = nil,
        primaryServiceID: String? = nil,
        serviceOrder: [String] = [],
        services: [NetworkServiceState] = []
    ) {
        self.primaryInterface = primaryInterface
        self.primaryServiceID = primaryServiceID
        self.serviceOrder = serviceOrder
        self.services = services
    }
}

public enum LocalNetworkDirectError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case noPhysicalInterface
    case invalidInterfaceName(String)
    case noUsableDNSServer

    public var errorDescription: String? {
        switch self {
        case .noPhysicalInterface:
            return L10n.text("找不到可用的本地物理网络，已中止启动（未回退到系统代理或 VPN）。")
        case .invalidInterfaceName(let name):
            return L10n.text("本地物理网络接口名无效：%@。", name)
        case .noUsableDNSServer:
            return L10n.text("找不到可用的本地 DNS 服务器，已中止启动。")
        }
    }

    public var description: String {
        errorDescription ?? String(reflecting: self)
    }
}

/// 自动识别活跃物理网卡与真实本地 DNS，过滤 Clash / VPN 虚拟网卡与 Fake-IP。
public enum LocalNetworkInterfaceResolver {
    public static let fallbackDirectDNSServers = ["223.5.5.5", "1.1.1.1"]

    private static let virtualInterfacePrefixes = [
        "utun", "tun", "tap", "ppp", "ipsec", "lo", "bridge",
        "awdl", "llw", "gif", "stf", "anpi", "ap", "vmenet", "feth", "pktap", "xhc",
    ]

    /// 判断接口名是否为虚拟/隧道/点对点/系统保留接口。
    public static func isVirtualInterface(_ rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return true }
        return virtualInterfacePrefixes.contains { name.hasPrefix($0) }
    }

    /// 判断 IPv4 是否为可用于物理直连的非保留单播地址（剔除 0/8、127/8、169.254/16、198.18/15 Fake-IP、多播）。
    static func isUsableUnicastIPv4(_ raw: String) -> Bool {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var addr4 = in_addr()
        guard inet_pton(AF_INET, candidate, &addr4) == 1 else { return false }
        let value = UInt32(bigEndian: addr4.s_addr)
        let b1 = (value >> 24) & 0xFF
        let b2 = (value >> 16) & 0xFF
        if b1 == 0 || b1 == 127 { return false }
        if b1 == 169 && b2 == 254 { return false }
        // Clash / Sing-box TUN 常用 Fake-IP 段（RFC 2544 基准测试网段 198.18.0.0/15）。
        if b1 == 198 && (b2 == 18 || b2 == 19) { return false }
        if b1 >= 224 { return false }
        return true
    }

    /// 判断是否可用于物理直连 DNS 地址（支持 IPv4 与非回环/非链路本地 IPv6）。
    public static func isUsableDirectDNSAddress(_ raw: String) -> Bool {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines).withoutIPv6Brackets
        guard !candidate.isEmpty, !candidate.contains("%") else { return false }
        if isUsableUnicastIPv4(candidate) { return true }
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, candidate, &addr6) == 1 {
            let bytes = withUnsafeBytes(of: addr6) { Array($0) }
            let isZero = bytes.allSatisfy { $0 == 0 }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
            let isMulticast = bytes[0] == 0xFF
            return !isZero && !isLoopback && !isLinkLocal && !isMulticast
        }
        return false
    }

    /// 规范化直连 DNS 列表：去空白、剥 IPv6 括号、过滤无效/回环/Fake-IP，按 IPv4 优先保序去重。
    public static func sanitizedDirectDNSServers(_ rawServers: [String]) -> [String] {
        var ipv4: [String] = []
        var ipv6: [String] = []
        var seen = Set<String>()
        for raw in rawServers {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).withoutIPv6Brackets
            guard isUsableDirectDNSAddress(trimmed), seen.insert(trimmed).inserted else { continue }
            if isUsableUnicastIPv4(trimmed) {
                ipv4.append(trimmed)
            } else {
                ipv6.append(trimmed)
            }
        }
        return ipv4 + ipv6
    }

    public static func resolveCurrent() throws -> LocalDirectNetworkTarget {
        try resolve(from: captureCurrentSnapshot())
    }

    public static func resolve(from snapshot: NetworkStateSnapshot) throws -> LocalDirectNetworkTarget {
        let physicalServices = snapshot.services.filter { service in
            !isVirtualInterface(service.interfaceName)
                && service.ipv4Addresses.contains(where: isUsableUnicastIPv4)
        }
        guard !physicalServices.isEmpty else {
            throw LocalNetworkDirectError.noPhysicalInterface
        }

        let selected: NetworkServiceState
        if let primaryID = snapshot.primaryServiceID,
           let match = physicalServices.first(where: { $0.id == primaryID }) {
            selected = match
        } else if let primaryIF = snapshot.primaryInterface,
                  !isVirtualInterface(primaryIF),
                  let match = physicalServices.first(where: { $0.interfaceName == primaryIF }) {
            selected = match
        } else {
            let orderIndex = Dictionary(uniqueKeysWithValues: snapshot.serviceOrder.enumerated().map { ($1, $0) })
            let sorted = physicalServices.sorted { lhs, rhs in
                let lHasRouter = lhs.router.map(isUsableDirectDNSAddress) ?? false
                let rHasRouter = rhs.router.map(isUsableDirectDNSAddress) ?? false
                if lHasRouter != rHasRouter { return lHasRouter }
                let lOrder = orderIndex[lhs.id] ?? Int.max
                let rOrder = orderIndex[rhs.id] ?? Int.max
                if lOrder != rOrder { return lOrder < rOrder }
                return lhs.interfaceName < rhs.interfaceName
            }
            selected = sorted[0]
        }

        let dns = resolvedDNSServers(for: selected)
        return LocalDirectNetworkTarget(interfaceName: selected.interfaceName, dnsServers: dns)
    }

    private static func resolvedDNSServers(for service: NetworkServiceState) -> [String] {
        let sanitized = sanitizedDirectDNSServers(service.dnsServers)
        if !sanitized.isEmpty { return sanitized }

        if let router = service.router?.trimmingCharacters(in: .whitespacesAndNewlines),
           isUsableDirectDNSAddress(router) {
            return [router]
        }
        return fallbackDirectDNSServers
    }

    static func captureCurrentSnapshot() -> NetworkStateSnapshot {
        guard let store = SCDynamicStoreCreate(nil, "SafarierLocalDirect" as CFString, nil, nil) else {
            return NetworkStateSnapshot()
        }
        let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let setupIPv4 = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primaryInterface = globalIPv4?[kSCDynamicStorePropNetPrimaryInterface as String] as? String
        let primaryServiceID = globalIPv4?[kSCDynamicStorePropNetPrimaryService as String] as? String
        let serviceOrder = setupIPv4?[kSCPropNetServiceOrder as String] as? [String] ?? []

        let keys = (SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String]) ?? []
        var services: [NetworkServiceState] = []
        for key in keys.sorted() {
            let parts = key.split(separator: "/")
            guard parts.count == 5 else { continue }
            let serviceID = String(parts[3])
            guard let ipv4Dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interfaceName = ipv4Dict[kSCPropInterfaceName as String] as? String else { continue }
            let addresses = ipv4Dict[kSCPropNetIPv4Addresses as String] as? [String] ?? []
            let router = ipv4Dict[kSCPropNetIPv4Router as String] as? String
            let dnsKey = "State:/Network/Service/\(serviceID)/DNS" as CFString
            let dnsDict = SCDynamicStoreCopyValue(store, dnsKey) as? [String: Any]
            let dnsServers = dnsDict?[kSCPropNetDNSServerAddresses as String] as? [String] ?? []
            services.append(NetworkServiceState(
                id: serviceID,
                interfaceName: interfaceName,
                ipv4Addresses: addresses,
                router: router,
                dnsServers: dnsServers
            ))
        }
        return NetworkStateSnapshot(
            primaryInterface: primaryInterface,
            primaryServiceID: primaryServiceID,
            serviceOrder: serviceOrder,
            services: services
        )
    }
}
