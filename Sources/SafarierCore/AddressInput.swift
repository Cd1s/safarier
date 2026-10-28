import Foundation

/// 地址栏输入 → 要打开的网址。像网址的直接打开（没写协议时补上），否则交给搜索引擎，和 Safari 一样。
public enum AddressInput {
    /// Safari 默认搜索引擎（Google）的查询格式。
    public static let searchURLPrefix = "https://www.google.com/search?client=safari&ie=UTF-8&oe=UTF-8&q="

    public static func url(for raw: String) -> URL? {
        let text = normalized(raw)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("about:") || lower.hasPrefix("data:") {
            return URL(string: text)
        }
        if text.contains("://"), !text.contains(" "), let url = URL(string: text), url.scheme != nil {
            // 只写了协议（`https://`）或主机是空的：不导航，免得打开一个必然失败的地址。
            if isWebScheme(url), url.host?.isEmpty ?? true { return nil }
            return url
        }
        if !text.contains(" "), let host = hostCandidate(text), let url = URL(string: "\(defaultScheme(forHost: host))://\(text)") {
            return url
        }
        return searchURL(text)
    }

    /// 只接受网页地址的地方（环境的起始网址）：和地址栏一样规范化、没写协议时补上，但不会变成搜索；
    /// 必须是有主机的 http / https 地址，否则返回 nil。
    public static func webURL(for raw: String) -> URL? {
        let text = normalized(raw)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let candidate: URL?
        if text.contains("://") {
            candidate = URL(string: text)
        } else if let host = hostCandidate(text) {
            candidate = URL(string: "\(defaultScheme(forHost: host))://\(text)")
        } else {
            candidate = nil
        }
        guard let url = candidate, isWebScheme(url), !(url.host ?? "").isEmpty else { return nil }
        return url
    }

    /// 复制来的网址常夹着看不见的格式字符（零宽空格、方向标记、BOM、软连字符、连接符等）：先去掉
    /// （零宽连接符 U+200D 保留，它是组合表情的一部分）。全角的 `。．｡：／` 换成半角后，只有网址的主机部分全是 ASCII
    /// 才采用（`ippure。com` → `ippure.com`），中文句子不会被当成网址。
    static func normalized(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { $0.properties.generalCategory != .format || $0 == "\u{200D}" }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = text
            .replacingOccurrences(of: "[。．｡]", with: ".", options: .regularExpression)
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "／", with: "/")
        guard mapped != text else { return text }
        let afterScheme = mapped.range(of: "://").map { String(mapped[$0.upperBound...]) } ?? mapped
        let authority = String(afterScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return authority.contains(".") && authority.unicodeScalars.allSatisfy(\.isASCII) ? mapped : text
    }

    /// 本机地址和 IP 一般没有证书，Safari 也用 http；其它网站先用 https。
    static func defaultScheme(forHost host: String) -> String {
        host == "localhost" || isIPAddress(host) ? "http" : "https"
    }

    static func isWebScheme(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    public static func searchURL(_ query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: searchURLPrefix + encoded)
    }

    /// 输入看起来像主机名（带点的域名、localhost、IP，可带端口和路径）时返回主机部分。
    static func hostCandidate(_ text: String) -> String? {
        let authority = String(text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        var host = authority
        if host.hasPrefix("[") {
            guard let end = host.firstIndex(of: "]") else { return nil }
            return String(host[host.index(after: host.startIndex)..<end])
        }
        if let colon = host.lastIndex(of: ":") {
            guard Int(host[host.index(after: colon)...]) != nil else { return nil }
            host = String(host[..<colon])
        }
        host = host.lowercased()
        if host == "localhost" || isIPAddress(host) { return host }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) || $0 == "." }) else { return nil }
        return host
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }
}
