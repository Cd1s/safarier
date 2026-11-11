import Foundation
import SafarierCore
import Yams

/// Import node data only. Clash listeners, routing, DNS and controller settings are never applied.
enum ClashSubscriptionParser {
    static func looksLikeClash(_ text: String) -> Bool {
        let pattern = #"(?m)^[ \t]*(?:proxies|"proxies"|'proxies')\s*:"#
        return text.range(of: pattern, options: .regularExpression) != nil || text.hasPrefix("{")
    }

    static func parseIfPresent(_ text: String) throws -> SubscriptionParseResult? {
        guard looksLikeClash(text) else { return nil }
        do {
            let document = try YAMLDecoder().decode(Document.self, from: text)
            var nodes: [SubscriptionNode] = []
            var skipped: [String: Int] = [:]
            var firstUnsupported: String?
            for entry in document.proxies {
                guard let proxy = entry.proxy else {
                    skipped[entry.type, default: 0] += 1
                    firstUnsupported = firstUnsupported ?? entry.type
                    continue
                }
                nodes.append(try proxy.node())
            }
            if nodes.isEmpty, let firstUnsupported {
                throw SubscriptionParseError.unsupportedScheme(firstUnsupported)
            }
            return SubscriptionParseResult(nodes: nodes, skippedSchemes: skipped)
        } catch let error as SubscriptionParseError {
            throw error
        } catch {
            // YAML decoder errors can contain the entire subscription, including credentials.
            throw SubscriptionParseError.invalidClash
        }
    }

    private struct Document: Decodable {
        let proxies: [Entry]
    }

    /// Unsupported entries need only a type; their protocol-specific fields may have other shapes.
    private struct Entry: Decodable {
        let type: String
        let proxy: Proxy?
        enum CodingKeys: String, CodingKey { case type }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type).lowercased()
            proxy = ["trojan", "anytls", "mieru", "vless", "hysteria2"].contains(type)
                ? try Proxy(from: decoder) : nil
        }
    }

    private struct Proxy: Decodable {
        let type: String
        let name: String?
        let server: String?
        let port: Int?
        let ports: String?
        let password: String?
        let sni: String?
        let skipCertVerify: Bool?
        let alpn: [String]?
        let obfs: String?
        let obfsPassword: String?
        let username: String?
        let uuid: String?
        let tls: Bool?
        let servername: String?
        let network: String?
        let transport: String?
        let flow: String?
        let clientFingerprint: String?
        let reality: Reality?
        let multiplexing: String?
        let ipVersion: String?
        let ws: WebSocket?
        let grpc: GRPC?

        struct Reality: Decodable {
            let publicKey: String
            let shortID: String?
            enum CodingKeys: String, CodingKey { case publicKey = "public-key", shortID = "short-id" }
        }
        struct WebSocket: Decodable {
            let path: String?
            let headers: [String: String]?
        }
        struct GRPC: Decodable {
            let serviceName: String?
            enum CodingKeys: String, CodingKey { case serviceName = "grpc-service-name" }
        }

        enum CodingKeys: String, CodingKey {
            case type, name, server, port, ports, password, sni, alpn, obfs
            case skipCertVerify = "skip-cert-verify"
            case obfsPassword = "obfs-password"
            case username, uuid, tls, servername, network, transport, flow, multiplexing
            case clientFingerprint = "client-fingerprint"
            case reality = "reality-opts"
            case ipVersion = "ip-version"
            case ws = "ws-opts"
            case grpc = "grpc-opts"
        }

        func node() throws -> SubscriptionNode {
            guard let name, let server, let nodeType = SubscriptionNodeType(rawValue: type.lowercased()) else {
                throw SubscriptionParseError.invalidClash
            }
            var parameters: [String: String] = [:]
            var firstPort = port
            if nodeType == .hysteria2, let ports {
                let ranges = try portRanges(ports)
                firstPort = ranges.first.flatMap { Int($0.split(separator: ":")[0]) }
                parameters["server_ports"] = ranges.joined(separator: ",")
            }
            guard let firstPort else { throw SubscriptionParseError.invalidClash }
            if let skipCertVerify { parameters["insecure"] = skipCertVerify ? "1" : "0" }
            if let alpn { parameters["alpn"] = alpn.joined(separator: ",") }
            if nodeType == .hysteria2, let obfs {
                guard obfs == "salamander", let obfsPassword, !obfsPassword.isEmpty else {
                    throw SubscriptionParseError.invalidClash
                }
                parameters["obfs"] = obfs
                parameters["obfs-password"] = obfsPassword
            }
            if let ipVersion {
                guard ["dual", "ipv4", "ipv6", "ipv4-prefer", "ipv6-prefer"].contains(ipVersion) else {
                    throw SubscriptionParseError.invalidClash
                }
                parameters["ip-version"] = ipVersion
            }
            if let clientFingerprint { parameters["fp"] = clientFingerprint }
            if let reality {
                guard nodeType == .vless, tls == true, !reality.publicKey.isEmpty else {
                    throw SubscriptionParseError.invalidClash
                }
                parameters["security"] = "reality"
                parameters["pbk"] = reality.publicKey
                parameters["sid"] = reality.shortID
            }
            if nodeType == .mieru { parameters["multiplexing"] = multiplexing }
            let nodeTransport = nodeType == .mieru ? (transport ?? "TCP").uppercased() : network?.lowercased()
            if nodeType != .mieru, let nodeTransport, !["tcp", "ws", "grpc"].contains(nodeTransport) {
                throw SubscriptionParseError.invalidClash
            }
            if [.anytls, .hysteria2].contains(nodeType), let nodeTransport, nodeTransport != "tcp" {
                throw SubscriptionParseError.invalidClash
            }
            if let serviceName = grpc?.serviceName { parameters["serviceName"] = serviceName }
            let node = SubscriptionNode(name: name, type: nodeType, server: server,
                                        serverPort: firstPort, uuid: uuid, username: username, password: password,
                                        tls: [.trojan, .anytls, .hysteria2].contains(nodeType) || tls == true,
                                        serverName: sni ?? servername, transport: nodeTransport,
                                        transportPath: ws?.path,
                                        transportHost: ws?.headers?.first(where: { $0.key.lowercased() == "host" })?.value,
                                        flow: flow, parameters: parameters)
            try node.validate()
            return node
        }

        private func portRanges(_ value: String) throws -> [String] {
            try value.split(separator: ",", omittingEmptySubsequences: false).map { item in
                let bounds = item.trimmingCharacters(in: .whitespaces)
                    .split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(bounds.count) else { throw SubscriptionParseError.invalidClash }
                let numbers = try bounds.map { bound -> Int in
                    guard let number = Int(bound), (1...65535).contains(number) else {
                        throw SubscriptionParseError.invalidClash
                    }
                    return number
                }
                guard numbers[0] <= numbers.last! else { throw SubscriptionParseError.invalidClash }
                return "\(numbers[0]):\(numbers.last!)"
            }
        }
    }
}
