import Foundation

/// 地址栏输入 → 要打开的网址。像网址的直接打开（没写协议时补上），否则交给搜索引擎，和 Safari 一样。
public enum AddressInput {
    /// Safari 默认搜索引擎（Google）的查询格式。
    public static let searchURLPrefix = "https://www.google.com/search?client=safari&ie=UTF-8&oe=UTF-8&q="

    public static func url(for raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("about:") || lower.hasPrefix("data:") {
            return URL(string: text)
        }
        if text.contains("://"), !text.contains(" "), let url = URL(string: text), url.scheme != nil {
            return url
        }
        if !text.contains(" "), let host = hostCandidate(text) {
            // 本机地址和 IP 一般没有证书，Safari 也用 http；其它网站先用 https。
            let scheme = host == "localhost" || isIPAddress(host) ? "http" : "https"
            if let url = URL(string: "\(scheme)://\(text)") { return url }
        }
        return searchURL(text)
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
