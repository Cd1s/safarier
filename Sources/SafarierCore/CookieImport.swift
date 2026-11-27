import Foundation

public enum CookieImportFormat: Equatable, Sendable {
    case json
    case netscape
}

public struct CookieImportResult: Equatable, Sendable {
    public let cookies: [HTTPCookie]
    public let skippedCount: Int
    public let format: CookieImportFormat

    public init(cookies: [HTTPCookie], skippedCount: Int, format: CookieImportFormat) {
        self.cookies = cookies
        self.skippedCount = skippedCount
        self.format = format
    }
}

public enum CookieImportError: Error, LocalizedError, Equatable {
    case emptyInput
    case invalidJSON(String)
    case noValidCookies

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return L10n.text("请粘贴 Cookie 内容或选择文件。")
        case .invalidJSON(let detail):
            return L10n.text("Cookie JSON 格式无效：%@", detail)
        case .noValidCookies:
            return L10n.text("未解析到有效的 Cookie，请检查格式（支持 JSON 数组或 Netscape cookies.txt）。")
        }
    }
}

public enum CookieImportParser {
    private static let httpOnlyPropertyKey = HTTPCookiePropertyKey("HttpOnly")

    /// 解析 JSON 数组（EditThisCookie / Cookie-Editor / AdsPower / Playwright）或 Netscape `cookies.txt`。
    public static func parse(_ raw: String) throws -> CookieImportResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CookieImportError.emptyInput }

        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            return try parseJSON(trimmed)
        }
        return try parseNetscape(trimmed)
    }

    private static func parseJSON(_ raw: String) throws -> CookieImportResult {
        guard let data = raw.data(using: .utf8) else {
            throw CookieImportError.invalidJSON("UTF-8")
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CookieImportError.invalidJSON(error.localizedDescription)
        }

        let items: [[String: Any]]
        if let array = json as? [[String: Any]] {
            items = array
        } else if let dict = json as? [String: Any], let array = dict["cookies"] as? [[String: Any]] {
            items = array
        } else {
            throw CookieImportError.invalidJSON(L10n.text("顶层应为 Cookie 数组或包含 cookies 数组的对象"))
        }

        var cookies: [HTTPCookie] = []
        var skipped = 0
        for item in items {
            if let cookie = makeCookie(from: item) {
                cookies.append(cookie)
            } else {
                skipped += 1
            }
        }
        guard !cookies.isEmpty else { throw CookieImportError.noValidCookies }
        return CookieImportResult(cookies: cookies, skippedCount: skipped, format: .json)
    }

    private static func makeCookie(from item: [String: Any]) -> HTTPCookie? {
        guard let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let value = item["value"] as? String,
              let rawDomain = (item["domain"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDomain.isEmpty else {
            return nil
        }

        let path = (item["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        let secure = boolValue(item["secure"]) ?? false
        let httpOnly = boolValue(item["httpOnly"]) ?? boolValue(item["httponly"]) ?? false
        let isSession = boolValue(item["session"]) ?? false

        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: rawDomain,
            .path: path,
        ]
        if secure {
            properties[.secure] = "TRUE"
        }
        if httpOnly {
            properties[httpOnlyPropertyKey] = "TRUE"
        }
        if !isSession, let expires = parseTimestamp(item["expirationDate"] ?? item["expires"] ?? item["expiry"]) {
            properties[.expires] = expires
        }
        if let sameSite = parseSameSite(item["sameSite"] as? String) {
            properties[.sameSitePolicy] = sameSite
        }

        return HTTPCookie(properties: properties)
    }

    private static func parseNetscape(_ raw: String) throws -> CookieImportResult {
        var cookies: [HTTPCookie] = []
        var skipped = 0

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            var httpOnly = false
            var content = trimmed
            if content.hasPrefix("#HttpOnly_") {
                httpOnly = true
                content = String(content.dropFirst("#HttpOnly_".count))
            } else if content.hasPrefix("#") {
                continue
            }

            let fields = content.components(separatedBy: "\t")
            guard fields.count >= 7 else {
                skipped += 1
                continue
            }

            let domain = fields[0].trimmingCharacters(in: .whitespaces)
            let path = fields[2].isEmpty ? "/" : fields[2]
            let secure = fields[3].caseInsensitiveCompare("TRUE") == .orderedSame || fields[3] == "1"
            let expiresRaw = Double(fields[4]) ?? 0
            let name = fields[5]
            let value = fields.dropFirst(6).joined(separator: "\t")

            guard !domain.isEmpty, !name.isEmpty else {
                skipped += 1
                continue
            }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
            ]
            if secure {
                properties[.secure] = "TRUE"
            }
            if httpOnly {
                properties[httpOnlyPropertyKey] = "TRUE"
            }
            if expiresRaw > 0 {
                properties[.expires] = normalizeEpochDate(expiresRaw)
            }

            if let cookie = HTTPCookie(properties: properties) {
                cookies.append(cookie)
            } else {
                skipped += 1
            }
        }

        guard !cookies.isEmpty else { throw CookieImportError.noValidCookies }
        return CookieImportResult(cookies: cookies, skippedCount: skipped, format: .netscape)
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            return seconds > 0 ? normalizeEpochDate(seconds) : nil
        }
        if let string = value as? String, let seconds = Double(string), seconds > 0 {
            return normalizeEpochDate(seconds)
        }
        return nil
    }

    private static func normalizeEpochDate(_ value: Double) -> Date {
        let seconds = value > 100_000_000_000 ? value / 1000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func parseSameSite(_ raw: String?) -> HTTPCookieStringPolicy? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        switch raw {
        case "lax":
            return .sameSiteLax
        case "strict":
            return .sameSiteStrict
        default:
            return nil
        }
    }
}
