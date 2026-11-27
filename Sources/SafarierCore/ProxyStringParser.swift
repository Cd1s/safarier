import Darwin
import Foundation

/// 解析粘贴到服务器栏的完整代理字符串（如 `ip:端口:用户名:密码`、`socks5://user:pass@host:port` 等）。
public struct ParsedProxyString: Equatable, Sendable {
    public var kind: ProxyKind?
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?

    public init(kind: ProxyKind? = nil, host: String, port: Int, username: String? = nil, password: String? = nil) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

public enum ProxyStringParser {
    /// 解析常见代理格式；普通域名或裸 IPv6 地址返回 `nil`。
    public static func parse(_ raw: String) -> ParsedProxyString? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return nil }

        if trimmed.contains("://") {
            return parseURL(trimmed)
        }
        if let atIndex = trimmed.lastIndex(of: "@") {
            return parseUserInfoAndEndpoint(
                userInfo: String(trimmed[..<atIndex]),
                endpoint: String(trimmed[trimmed.index(after: atIndex)...]),
                kind: nil
            )
        }
        return parseColonDelimited(trimmed)
    }

    /// 供文本框 `onChange` 使用：逐字追加 `host:port` 时不打断输入，粘贴或含认证/协议头时立即填充。
    public static func parseForAutoFill(oldValue: String, newValue: String) -> ParsedProxyString? {
        guard let parsed = parse(newValue) else { return nil }
        let isSingleCharAppend = newValue.count == oldValue.count + 1 && newValue.hasPrefix(oldValue)
        if isSingleCharAppend && parsed.username == nil && parsed.kind == nil {
            return nil
        }
        return parsed
    }

    private static func parseURL(_ text: String) -> ParsedProxyString? {
        guard let schemeEnd = text.range(of: "://") else { return nil }
        let scheme = text[..<schemeEnd.lowerBound].lowercased()
        let kind: ProxyKind?
        switch scheme {
        case "socks5", "socks5h", "socks":
            kind = .socks5
        case "http", "https":
            kind = .httpConnect
        default:
            return nil
        }

        let rest = String(text[schemeEnd.upperBound...])
        // 去掉末尾路径（例如 http://host:port/）
        let authority = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rest
        if let atIndex = authority.lastIndex(of: "@") {
            return parseUserInfoAndEndpoint(
                userInfo: String(authority[..<atIndex]),
                endpoint: String(authority[authority.index(after: atIndex)...]),
                kind: kind,
                percentDecodeUserInfo: true
            )
        }
        guard var parsed = parseColonDelimited(authority) else { return nil }
        parsed.kind = kind
        return parsed
    }

    private static func parseUserInfoAndEndpoint(
        userInfo: String,
        endpoint: String,
        kind: ProxyKind?,
        percentDecodeUserInfo: Bool = false
    ) -> ParsedProxyString? {
        guard let (host, port, trailing) = parseHostPort(endpoint), trailing.isEmpty else { return nil }
        let (rawUser, rawPass) = splitFirstColon(userInfo)
        let user = percentDecodeUserInfo ? (rawUser.removingPercentEncoding ?? rawUser) : rawUser
        let pass = rawPass.map { percentDecodeUserInfo ? ($0.removingPercentEncoding ?? $0) : $0 }
        guard !user.isEmpty else { return nil }
        return ParsedProxyString(
            kind: kind,
            host: host,
            port: port,
            username: user,
            password: pass
        )
    }

    private static func parseColonDelimited(_ text: String) -> ParsedProxyString? {
        if isBareIPv6(text) { return nil }
        guard let (host, port, trailing) = parseHostPort(text) else { return nil }
        if trailing.isEmpty {
            return ParsedProxyString(host: host, port: port)
        }
        // trailing 形如 "username" 或 "username:password"（支持全角冒号分隔）
        let (user, pass) = splitFirstColon(trailing)
        guard !user.isEmpty else { return nil }
        return ParsedProxyString(
            host: host,
            port: port,
            username: user,
            password: pass
        )
    }

    /// 解析 `[ipv6]:port[:rest]` 或 `host:port[:rest]`（支持半角 `:` 与全角 `：`）。
    private static func parseHostPort(_ text: String) -> (host: String, port: Int, trailing: String)? {
        if text.hasPrefix("[") {
            guard let closeBracket = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<closeBracket])
            let afterBracket = text[text.index(after: closeBracket)...]
            guard let first = afterBracket.first, first == ":" || first == "：" else { return nil }
            let afterColon = String(afterBracket.dropFirst())
            let (portString, trailing) = splitFirstColon(afterColon)
            guard !host.isEmpty, let port = parsePort(portString) else { return nil }
            return (host, port, trailing ?? "")
        }

        let (host, afterHost) = splitFirstColon(text)
        guard let afterHost, !host.isEmpty else { return nil }
        let (portString, trailing) = splitFirstColon(afterHost)
        guard let port = parsePort(portString) else { return nil }
        return (host, port, trailing ?? "")
    }

    private static func splitFirstColon(_ text: String) -> (String, String?) {
        guard let index = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return (text, nil)
        }
        return (String(text[..<index]), String(text[text.index(after: index)...]))
    }

    private static func parsePort(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
              let port = Int(text), (1...65535).contains(port) else {
            return nil
        }
        return port
    }

    private static func isBareIPv6(_ text: String) -> Bool {
        var addr = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }
}
