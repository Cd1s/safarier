import Foundation

/// 一条浏览记录。
public struct BrowsingHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var visitedAt: Date

    public init(id: UUID = UUID(), url: URL, title: String, visitedAt: Date) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }

    /// 列表和菜单里显示的名字：网页没有标题时用域名。
    public var displayTitle: String {
        title.isEmpty ? (url.host ?? url.absoluteString) : title
    }
}

/// 历史记录页上的一组（今天 / 更早）。
public struct BrowsingHistorySection: Equatable, Sendable {
    public var title: String
    public var entries: [BrowsingHistoryEntry]

    public init(title: String, entries: [BrowsingHistoryEntry]) {
        self.title = title
        self.entries = entries
    }
}

/// 按环境隔离的浏览历史。
///
/// - 持久环境：存在元数据目录的 `history/<PROFILE_ID>.json`（目录 0700、文件 0600），最多留最近 `limit` 条；
///   还记着环境上次关闭时开着的标签网址（`lastSessionTabURLs`），「历史记录 → 重新打开上次会话的所有标签页」用；
/// - 临时环境（`fileURL` 为 nil）：只放在内存里，环境关闭就没了，从不落盘。
///
/// 只记 http / https 网页。同一个网址再访问时移到最前面、更新标题和时间，不重复记。
/// 文件坏了就当成空的，下一次改动时重写。
@MainActor
public final class BrowsingHistoryStore {
    public static let didChangeNotification = Notification.Name("SafarierBrowsingHistoryStoreDidChange")
    public static let limit = 500

    private struct Document: Codable {
        var version: Int
        var entries: [BrowsingHistoryEntry]
        var lastSessionTabURLs: [URL]
    }

    private static let currentVersion = 1

    /// nil：只在内存里（临时环境）。
    public let fileURL: URL?
    /// 最新的在前。
    public private(set) var entries: [BrowsingHistoryEntry] = []
    public private(set) var lastSessionTabURLs: [URL] = []

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        guard let document = try? decoder.decode(Document.self, from: data), document.version <= Self.currentVersion else { return }
        entries = Array(document.entries.sorted { $0.visitedAt > $1.visitedAt }.prefix(Self.limit))
        lastSessionTabURLs = document.lastSessionTabURLs.filter(Self.isRecordable)
    }

    /// 持久环境落盘到 `workspace.historyURL(for:)`；临时环境只在内存里。
    public static func store(for profile: Profile, in workspace: SafarierWorkspace) -> BrowsingHistoryStore {
        BrowsingHistoryStore(fileURL: profile.mode == .persistent ? workspace.historyURL(for: profile.id) : nil)
    }

    /// 只记有主机的 http / https 网址：起始页（about:blank）、data:、blob:、file: 都不记。
    public nonisolated static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host?.isEmpty == false
    }

    // MARK: - 修改

    /// 打开了一个网页。
    public func recordVisit(_ url: URL, title: String?, at date: Date = Date()) {
        guard Self.isRecordable(url) else { return }
        let previous = entries.firstIndex { $0.url.absoluteString == url.absoluteString }.map { entries.remove(at: $0) }
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let entry = BrowsingHistoryEntry(
            id: previous?.id ?? UUID(),
            url: url,
            title: cleanTitle.isEmpty ? (previous?.title ?? "") : cleanTitle,
            visitedAt: date
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        changed()
    }

    /// 网页载入完之后才改标题（单页应用）：更新这个网址的记录。
    public func updateTitle(_ title: String, for url: URL) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = entries.firstIndex(where: { $0.url.absoluteString == url.absoluteString }),
              entries[index].title != clean else { return }
        entries[index].title = clean
        changed()
    }

    public func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        changed()
    }

    /// 清除历史记录：浏览记录和上次会话的标签一起清掉。
    public func clear() {
        guard !entries.isEmpty || !lastSessionTabURLs.isEmpty else { return }
        entries = []
        lastSessionTabURLs = []
        changed()
    }

    /// 环境关闭时开着的标签（按标签顺序）。
    public func setLastSessionTabURLs(_ urls: [URL]) {
        let recordable = urls.filter(Self.isRecordable)
        guard recordable != lastSessionTabURLs else { return }
        lastSessionTabURLs = recordable
        changed()
    }

    // MARK: - 查询

    /// 标题或网址里含有 `query`（不分大小写）；空查询返回全部。
    public func entries(matching query: String) -> [BrowsingHistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.url.absoluteString.localizedCaseInsensitiveContains(needle)
        }
    }

    /// 历史记录菜单底部列出的最近几条。
    public func recentEntries(_ count: Int) -> [BrowsingHistoryEntry] {
        Array(entries.prefix(max(0, count)))
    }

    /// 按「今天 / 更早」分组，组内最新的在前；空组不返回。
    public nonisolated static func sections(for entries: [BrowsingHistoryEntry], now: Date = Date(), calendar: Calendar = .current) -> [BrowsingHistorySection] {
        let sorted = entries.sorted { $0.visitedAt > $1.visitedAt }
        let today = sorted.filter { calendar.isDate($0.visitedAt, inSameDayAs: now) }
        let earlier = sorted.filter { !calendar.isDate($0.visitedAt, inSameDayAs: now) }
        return [BrowsingHistorySection(title: "今天", entries: today), BrowsingHistorySection(title: "更早", entries: earlier)]
            .filter { !$0.entries.isEmpty }
    }

    // MARK: - 存盘

    private func changed() {
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// 先写同目录下的 0600 临时文件再改名，文件在任何时刻都不会是别人可读的。
    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(Document(version: Self.currentVersion, entries: entries, lastSessionTabURLs: lastSessionTabURLs))
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
            }
            guard rename(temporary.path, fileURL.path) == 0 else {
                let code = errno
                try? FileManager.default.removeItem(at: temporary)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        } catch {
            FileHandle.standardError.write(Data("[history] 保存历史记录失败：\(error)\n".utf8))
        }
    }
}
