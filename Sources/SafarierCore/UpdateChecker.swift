import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `major.minor.patch` 版本号。接受 `v` / `V` 前缀；缺的段按 0 补；`-beta.1`、`+build` 之类的后缀只用来识别，不参与比较。
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, first == "v" || first == "V" { text.removeFirst() }
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { text = String(text[..<cut]) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// Release 里的一个附件（zip、.sha256 等）。
public struct ReleaseAsset: Equatable, Sendable {
    public let name: String
    public let downloadURL: URL

    public init(name: String, downloadURL: URL) {
        self.name = name
        self.downloadURL = downloadURL
    }
}

/// GitHub Releases API 里用得到的几个字段。
public struct ReleaseInfo: Equatable, Sendable, Identifiable {
    public var id: String { tagName }
    public let tagName: String
    public let name: String
    public let body: String
    public let htmlURL: URL
    public let assets: [ReleaseAsset]

    public init(tagName: String, name: String, body: String, htmlURL: URL, assets: [ReleaseAsset] = []) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.assets = assets
    }

    /// 当前架构（`arm64` / `x86_64`）的 zip；没有就退回 universal。
    public func preferredZipAsset(arch: String) -> ReleaseAsset? {
        let lowered = arch.lowercased()
        return assets.first { $0.name.lowercased().hasSuffix("-\(lowered).zip") }
            ?? assets.first { $0.name.lowercased().hasSuffix("-universal.zip") }
    }

    /// `<zip 名>.sha256` 校验文件。
    public func sha256Asset(for zipAsset: ReleaseAsset) -> ReleaseAsset? {
        assets.first { $0.name == zipAsset.name + ".sha256" }
    }
}

public enum UpdateStatus: Equatable, Sendable {
    case upToDate(current: String, latest: ReleaseInfo)
    case updateAvailable(current: String, latest: ReleaseInfo)
}

public enum UpdateCheckError: Error, Equatable, LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidVersion(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub 返回的数据无法识别"
        case .httpStatus(let code): return "GitHub 返回 HTTP \(code)"
        case .invalidVersion(let text): return "无法识别版本号：\(text)"
        }
    }
}

/// 检查 GitHub 上的最新 Release。管理器启动时静默查一次、用户点「检查更新…」时再查一次，不轮询、不带任何环境数据。
/// 浏览器（Runner）进程不要调用 `checkLatest`：它的直连请求不走环境的代理，会泄露真实 IP。
public enum UpdateChecker {
    public static let repositoryURL = URL(string: "https://github.com/Cd1s/safarier")!
    public static let releasesURL = URL(string: "https://github.com/Cd1s/safarier/releases/latest")!
    public static let issuesURL = URL(string: "https://github.com/Cd1s/safarier/issues")!
    public static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/Cd1s/safarier/releases/latest")!

    private struct Payload: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String?
        let assets: [AssetPayload]?
    }

    private struct AssetPayload: Decodable {
        let name: String
        let browser_download_url: String
    }

    public static func parseRelease(from data: Data) throws -> ReleaseInfo {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.tag_name.isEmpty else { throw UpdateCheckError.invalidResponse }
        // 响应里的链接只在确实指向本仓库时才用，其余一律退回 Releases 页面，避免被带去别的地方。
        let pageURL = payload.html_url.flatMap(URL.init(string:)).flatMap { isRepositoryURL($0) ? $0 : nil } ?? releasesURL
        let title = payload.name.flatMap { $0.isEmpty ? nil : $0 } ?? payload.tag_name
        // 下载链接同样只认本仓库 Release 下的附件。
        let assets = (payload.assets ?? []).compactMap { asset -> ReleaseAsset? in
            guard let url = URL(string: asset.browser_download_url), isReleaseDownloadURL(url), !asset.name.isEmpty else { return nil }
            return ReleaseAsset(name: asset.name, downloadURL: url)
        }
        return ReleaseInfo(tagName: payload.tag_name, name: title, body: payload.body ?? "", htmlURL: pageURL, assets: assets)
    }

    /// `.sha256` 文件第一个空白字符前的十六进制摘要（忽略大小写）与 `data` 的 SHA-256 比对。
    public static func verifySHA256(data: Data, expectedFileText: String) -> Bool {
        guard let expected = expectedFileText.split(whereSeparator: \.isWhitespace).first else { return false }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == expected.lowercased()
    }

    public static func compare(currentVersion: String, latest: ReleaseInfo) throws -> UpdateStatus {
        guard let current = SemanticVersion(currentVersion) else { throw UpdateCheckError.invalidVersion(currentVersion) }
        guard let newest = SemanticVersion(latest.tagName) else { throw UpdateCheckError.invalidVersion(latest.tagName) }
        return newest > current
            ? .updateAvailable(current: currentVersion, latest: latest)
            : .upToDate(current: currentVersion, latest: latest)
    }

    public static func checkLatest(
        currentVersion: String,
        load: (URLRequest) async throws -> (Data, URLResponse) = defaultLoad
    ) async throws -> UpdateStatus {
        var request = URLRequest(url: latestReleaseAPIURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Safarier/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await load(request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateCheckError.httpStatus(http.statusCode)
        }
        return try compare(currentVersion: currentVersion, latest: parseRelease(from: data))
    }

    /// 临时会话：不读写 Cookie 和缓存。
    @Sendable
    public static func defaultLoad(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    private static func isReleaseDownloadURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com" && url.path.lowercased().hasPrefix("/cd1s/safarier/releases/download/") && !url.path.contains("..")
    }

    private static func isRepositoryURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com" && url.path.lowercased().hasPrefix("/cd1s/safarier/")
    }
}
