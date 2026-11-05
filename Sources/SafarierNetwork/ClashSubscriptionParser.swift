import Foundation
import SafarierCore
import Yams

/// Import node data only. Clash listeners, routing, DNS and controller settings are never applied.
enum ClashSubscriptionParser {
    static func parseIfPresent(_ text: String) throws -> SubscriptionParseResult? {
        let pattern = #"(?m)^[ \t]*(?:proxies|"proxies"|'proxies')\s*:"#
        guard text.range(of: pattern, options: .regularExpression) != nil || text.hasPrefix("{") else {
            return nil
        }
        do {
            let document = try YAMLDecoder().decode(Document.self, from: text)
            var nodes: [SubscriptionNode] = []
            var skipped: [String: Int] = [:]
            var firstUnsupported: String?
            for proxy in document.proxies {
                guard proxy.type == "hysteria2" else {
                    skipped[proxy.type, default: 0] += 1
                    firstUnsupported = firstUnsupported ?? proxy.type
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
        let proxies: [Proxy]
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

        enum CodingKeys: String, CodingKey {
            case type, name, server, port, ports, password, sni, alpn, obfs
            case skipCertVerify = "skip-cert-verify"
            case obfsPassword = "obfs-password"
        }

        func node() throws -> SubscriptionNode {
            guard let name, let server, let password else { throw SubscriptionParseError.invalidClash }
            var parameters: [String: String] = [:]
            var firstPort = port
            if let ports {
                let ranges = try portRanges(ports)
                firstPort = ranges.first.flatMap { Int($0.split(separator: ":")[0]) }
                parameters["server_ports"] = ranges.joined(separator: ",")
            }
            guard let firstPort else { throw SubscriptionParseError.invalidClash }
            if let skipCertVerify { parameters["insecure"] = skipCertVerify ? "1" : "0" }
            if let alpn { parameters["alpn"] = alpn.joined(separator: ",") }
            if let obfs {
                guard obfs == "salamander", let obfsPassword, !obfsPassword.isEmpty else {
                    throw SubscriptionParseError.invalidClash
                }
                parameters["obfs"] = obfs
                parameters["obfs-password"] = obfsPassword
            }
            let node = SubscriptionNode(name: name, type: .hysteria2, server: server,
                                        serverPort: firstPort, password: password, tls: true,
                                        serverName: sni, parameters: parameters)
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
