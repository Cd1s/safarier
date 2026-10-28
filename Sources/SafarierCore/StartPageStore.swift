import Foundation

/// 起始页上的一个个人收藏。图标是本地画的品牌色磁贴（SF Symbol 或文字），不联网取网站图标：
/// 起始页在 Runner 进程里，联网会绕过这个环境的代理。
public struct StartPageFavorite: Codable, Equatable, Identifiable, Sendable {
    public var title: String
    public var url: URL
    /// SF Symbol 名；有它就画符号，否则画 `glyph` 文字。
    public var symbol: String?
    /// 磁贴上的文字（首字、「yahoo!」等）。
    public var glyph: String?
    /// 文字字体：`serif`（Wikipedia 的 W）、`rounded`，nil 为系统粗体。
    public var glyphDesign: String?
    /// `#RRGGBB`
    public var background: String
    public var foreground: String

    public var id: String { url.absoluteString }

    public init(title: String, url: URL, symbol: String? = nil, glyph: String? = nil, glyphDesign: String? = nil, background: String, foreground: String) {
        self.title = title
        self.url = url
        self.symbol = symbol
        self.glyph = glyph
        self.glyphDesign = glyphDesign
        self.background = background
        self.foreground = foreground
    }
}

/// 起始页的区块。
public enum StartPageSection: String, Codable, CaseIterable, Sendable {
    case favorites
    case suggestions
    case privacyReport
}

/// 存在磁盘上的起始页设置：个人收藏和各区块的显示开关。
public struct StartPageSettings: Codable, Equatable, Sendable {
    public var favorites: [StartPageFavorite]
    public var hiddenSections: [StartPageSection]

    public init(favorites: [StartPageFavorite] = StartPageStore.defaultFavorites, hiddenSections: [StartPageSection] = []) {
        self.favorites = favorites
        self.hiddenSections = hiddenSections
    }
}

public enum StartPageStoreError: Error, Equatable {
    /// 不是有主机的 http / https 网址。
    case invalidAddress
    /// 已经在个人收藏里了。
    case duplicate
}

/// 起始页设置的读写。每个 Runner 进程用同一个 `shared`，改动后发 `didChangeNotification`，同一进程里的各个标签一起刷新；
/// 文件放在元数据目录（`SAFARIER_HOME` 可覆盖）的 `start-page.json`，所有环境共用。文件坏了就用默认值，等下一次改动再写回。
@MainActor
public final class StartPageStore {
    public static let didChangeNotification = Notification.Name("SafarierStartPageStoreDidChange")
    public static let fileName = "start-page.json"

    public static let shared = StartPageStore(fileURL: try? FileManager.safarierSupportDirectory().appendingPathComponent(fileName))

    /// nil：只放在内存里（测试用）。
    public let fileURL: URL?
    public private(set) var settings: StartPageSettings

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(StartPageSettings.self, from: data) {
            settings = decoded
            // Retain the retired hostname as UTF-8 bytes only for upgrading saved defaults.
            let retiredHost = String(decoding: [105, 112, 112, 117, 114, 101, 46, 99, 111, 109], as: UTF8.self)
            let retiredURL = URL(string: "https://" + retiredHost)!
            var hasReplacement = decoded.favorites.contains { Self.sameSite($0.url, Self.ipCheckFavorite.url) }
            settings.favorites = decoded.favorites.compactMap { favorite in
                guard Self.sameSite(favorite.url, retiredURL) else { return favorite }
                guard !hasReplacement else { return nil }
                hasReplacement = true
                return Self.ipCheckFavorite
            }
            if settings != decoded { commit() }
        } else {
            settings = StartPageSettings()
        }
    }

    public var favorites: [StartPageFavorite] { settings.favorites }

    public func isVisible(_ section: StartPageSection) -> Bool {
        !settings.hiddenSections.contains(section)
    }

    public func setSection(_ section: StartPageSection, visible: Bool) {
        guard isVisible(section) != visible else { return }
        if visible {
            settings.hiddenSections.removeAll { $0 == section }
        } else {
            settings.hiddenSections.append(section)
        }
        commit()
    }

    /// 地址按地址栏的规则解析（去掉看不见的字符、没写协议补 https），必须是网页地址；名字空着就用域名。
    @discardableResult
    public func addFavorite(title: String, address: String) -> Result<StartPageFavorite, StartPageStoreError> {
        guard let url = AddressInput.webURL(for: address) else { return .failure(.invalidAddress) }
        guard !settings.favorites.contains(where: { Self.sameSite($0.url, url) }) else { return .failure(.duplicate) }
        let host = (url.host ?? url.absoluteString).replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let favorite = Self.customFavorite(title: name.isEmpty ? host : name, url: url, host: host)
        settings.favorites.append(favorite)
        commit()
        return .success(favorite)
    }

    public func removeFavorite(url: URL) {
        let before = settings.favorites.count
        settings.favorites.removeAll { Self.sameSite($0.url, url) }
        if settings.favorites.count != before { commit() }
    }

    public func restoreDefaultFavorites() {
        settings.favorites = Self.defaultFavorites
        commit()
    }

    private func commit() {
        if let fileURL {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(settings).write(to: fileURL, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("[start-page] 保存起始页设置失败：\(error)\n".utf8))
            }
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// 同一个网址（忽略末尾的 `/` 和 scheme 大小写）。
    nonisolated static func sameSite(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String {
            var text = url.absoluteString.lowercased()
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return key(a) == key(b)
    }

    /// 自己加的网站：首字 + 按域名固定的颜色（不用 hashValue，它每次启动都不一样）。
    nonisolated static func customFavorite(title: String, url: URL, host: String) -> StartPageFavorite {
        let palette = ["#5E5CE6", "#0A84FF", "#30B0C7", "#34C759", "#FF9F0A", "#FF375F", "#BF5AF2", "#8E8E93", "#A2845E", "#64D2FF"]
        let hash = host.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        let glyph = title.first.map { String($0).uppercased() } ?? "?"
        return StartPageFavorite(title: title, url: url, glyph: glyph, background: palette[Int(hash % UInt32(palette.count))], foreground: "#FFFFFF")
    }

    /// 默认的 16 个常用站点（8 列 × 2 行）。
    public nonisolated static let defaultFavorites: [StartPageFavorite] = [
        favorite("Apple", "https://www.apple.com", symbol: "apple.logo", background: "#F2F2F7", foreground: "#1D1D1F"),
        favorite("iCloud", "https://www.icloud.com", symbol: "icloud.fill", background: "#FFFFFF", foreground: "#3B82F6"),
        favorite("Google", "https://www.google.com", glyph: "G", background: "#FFFFFF", foreground: "#4285F4"),
        favorite("YouTube", "https://www.youtube.com", symbol: "play.fill", background: "#FF0033", foreground: "#FFFFFF"),
        favorite("ChatGPT", "https://chatgpt.com", symbol: "sparkle", background: "#ECECF1", foreground: "#0D0D0D"),
        favorite("Claude", "https://claude.ai", symbol: "asterisk", background: "#C96442", foreground: "#FFFFFF"),
        favorite("GitHub", "https://github.com", symbol: "chevron.left.forwardslash.chevron.right", background: "#24292F", foreground: "#FFFFFF"),
        favorite("X", "https://x.com", glyph: "X", background: "#000000", foreground: "#FFFFFF"),
        favorite("Wikipedia", "https://www.wikipedia.org", glyph: "W", design: "serif", background: "#FFFFFF", foreground: "#000000"),
        ipCheckFavorite,
        favorite("BrowserLeaks", "https://browserleaks.com", symbol: "eye.fill", background: "#1E3A5F", foreground: "#FFFFFF"),
        favorite("LINUX DO", "https://linux.do", glyph: "L", background: "#1F1F1F", foreground: "#F5C518"),
        favorite("Gmail", "https://mail.google.com", symbol: "envelope.fill", background: "#FFFFFF", foreground: "#EA4335"),
        favorite("Reddit", "https://www.reddit.com", glyph: "r", design: "rounded", background: "#FF4500", foreground: "#FFFFFF"),
        favorite("Yahoo", "https://www.yahoo.com", glyph: "yahoo!", background: "#6001D2", foreground: "#FFFFFF"),
        favorite("Telegram", "https://web.telegram.org", symbol: "paperplane.fill", background: "#229ED9", foreground: "#FFFFFF"),
    ]

    private nonisolated static let ipCheckFavorite = favorite(
        "IPCheck.ing", "https://ipcheck.ing", symbol: "network", background: "#4F46E5", foreground: "#FFFFFF"
    )

    private nonisolated static func favorite(
        _ title: String, _ address: String, symbol: String? = nil, glyph: String? = nil, design: String? = nil,
        background: String, foreground: String
    ) -> StartPageFavorite {
        StartPageFavorite(title: title, url: URL(string: address)!, symbol: symbol, glyph: glyph, glyphDesign: design,
                          background: background, foreground: foreground)
    }
}
