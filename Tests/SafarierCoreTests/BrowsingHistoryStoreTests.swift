import XCTest
@testable import SafarierCore

/// 按环境隔离的浏览历史：持久环境 0600 落盘并能读回，临时环境只在内存里；去重、500 条上限、只记网页、搜索和分组。
@MainActor
final class BrowsingHistoryStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowsingHistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testPersistentStoreWritesPrivateFileAndReadsItBack() throws {
        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "work", mode: .persistent)
        let store = BrowsingHistoryStore.store(for: profile, in: workspace)
        XCTAssertEqual(store.fileURL, root.appendingPathComponent("history/\(profile.id.uuidString).json"))
        XCTAssertEqual(store.fileURL, workspace.historyURL(for: profile.id))

        store.recordVisit(url("https://a.example.invalid/"), title: "A", at: Date(timeIntervalSince1970: 1_000))
        store.recordVisit(url("https://b.example.invalid/x?q=1"), title: "B", at: Date(timeIntervalSince1970: 2_000))
        store.setLastSessionTabURLs([url("https://a.example.invalid/"), url("https://c.example.invalid/")])

        let file = try XCTUnwrap(store.fileURL)
        XCTAssertEqual(try permissions(file), 0o600, "历史文件只有自己可读写")
        XCTAssertEqual(try permissions(workspace.historyDirectory), 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workspace.historyDirectory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "临时文件改名后不留下")

        let reloaded = BrowsingHistoryStore(fileURL: file)
        XCTAssertEqual(reloaded.entries, store.entries)
        XCTAssertEqual(reloaded.entries.map(\.title), ["B", "A"], "最新的在前")
        XCTAssertEqual(reloaded.lastSessionTabURLs, [url("https://a.example.invalid/"), url("https://c.example.invalid/")])

        let raw = try String(contentsOf: file, encoding: .utf8)
        for key in ["\"id\"", "\"url\"", "\"title\"", "\"visitedAt\"", "\"lastSessionTabURLs\""] {
            XCTAssertTrue(raw.contains(key), "文件里应有 \(key)")
        }
    }

    func testRevisitMovesEntryToTopWithoutDuplicating() {
        let store = BrowsingHistoryStore(fileURL: nil)
        let a = url("https://a.example.invalid/")
        store.recordVisit(a, title: "A", at: Date(timeIntervalSince1970: 1))
        let id = store.entries[0].id
        store.recordVisit(url("https://b.example.invalid/"), title: "B", at: Date(timeIntervalSince1970: 2))
        store.recordVisit(a, title: nil, at: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(store.entries.map(\.url), [a, url("https://b.example.invalid/")])
        XCTAssertEqual(store.entries[0].id, id, "同一个网址沿用原来的记录")
        XCTAssertEqual(store.entries[0].title, "A", "这次没有标题时保留上次的标题")
        XCTAssertEqual(store.entries[0].visitedAt, Date(timeIntervalSince1970: 3))
    }

    func testKeepsOnlyTheMostRecent500Entries() throws {
        let file = root.appendingPathComponent("history/limit.json")
        let store = BrowsingHistoryStore(fileURL: file)
        for index in 0..<510 {
            store.recordVisit(url("https://site\(index).example.invalid/"), title: "\(index)", at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(BrowsingHistoryStore.limit, 500)
        XCTAssertEqual(store.entries.count, 500)
        XCTAssertEqual(store.entries.first?.title, "509")
        XCTAssertEqual(store.entries.last?.title, "10")
        XCTAssertEqual(BrowsingHistoryStore(fileURL: file).entries.count, 500)
    }

    func testOnlyWebPagesAreRecorded() {
        let store = BrowsingHistoryStore(fileURL: nil)
        for text in ["about:blank", "data:text/html,hi", "file:///etc/hosts", "javascript:void(0)", "blob:https://x.example.invalid/1", "https:///nohost"] {
            store.recordVisit(url(text), title: text)
        }
        XCTAssertEqual(store.entries, [])
        store.recordVisit(url("http://plain.example.invalid/"), title: "plain")
        store.recordVisit(url("https://secure.example.invalid/"), title: "secure")
        XCTAssertEqual(store.entries.count, 2)
        store.setLastSessionTabURLs([url("about:blank"), url("https://secure.example.invalid/")])
        XCTAssertEqual(store.lastSessionTabURLs, [url("https://secure.example.invalid/")], "起始页不算会话标签")
    }

    func testTitleUpdateRemoveSearchAndClear() {
        let store = BrowsingHistoryStore(fileURL: nil)
        let docs = url("https://docs.example.invalid/guide")
        store.recordVisit(docs, title: "")
        store.recordVisit(url("https://news.example.invalid/today"), title: "Morning News")
        XCTAssertEqual(store.entries.first { $0.url == docs }?.displayTitle, "docs.example.invalid", "没有标题时显示域名")
        store.updateTitle("  Developer Guide  ", for: docs)
        XCTAssertEqual(store.entries.first { $0.url == docs }?.title, "Developer Guide")

        XCTAssertEqual(store.entries(matching: "guide").map(\.url), [docs], "按标题")
        XCTAssertEqual(store.entries(matching: "NEWS.EXAMPLE").count, 1, "按网址，不分大小写")
        XCTAssertEqual(store.entries(matching: "  ").count, 2, "空查询返回全部")
        XCTAssertEqual(store.entries(matching: "nothing").count, 0)
        XCTAssertEqual(store.recentEntries(1).map(\.title), ["Morning News"])

        let removed = store.entries[0].id
        store.remove(removed)
        XCTAssertFalse(store.entries.contains { $0.id == removed })

        store.setLastSessionTabURLs([docs])
        store.clear()
        XCTAssertEqual(store.entries, [])
        XCTAssertEqual(store.lastSessionTabURLs, [], "清除历史记录也清掉上次会话的标签")
    }

    func testChangesPostNotification() {
        let store = BrowsingHistoryStore(fileURL: nil)
        let posted = expectation(forNotification: BrowsingHistoryStore.didChangeNotification, object: store)
        store.recordVisit(url("https://a.example.invalid/"), title: "A")
        wait(for: [posted], timeout: 1)
    }

    func testEphemeralProfileNeverTouchesDisk() throws {
        let workspace = SafarierWorkspace(root: root)
        let store = BrowsingHistoryStore.store(for: Profile(name: "private", mode: .ephemeral), in: workspace)
        XCTAssertNil(store.fileURL)
        store.recordVisit(url("https://a.example.invalid/"), title: "A")
        store.setLastSessionTabURLs([url("https://a.example.invalid/")])
        XCTAssertEqual(store.entries.count, 1, "临时环境在内存里照常记")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.historyDirectory.path), "临时环境从不落盘")
    }

    func testCorruptFileIsTreatedAsEmptyAndRewritten() throws {
        let file = root.appendingPathComponent("history/broken.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let store = BrowsingHistoryStore(fileURL: file)
        XCTAssertEqual(store.entries, [])
        store.recordVisit(url("https://a.example.invalid/"), title: "A")
        XCTAssertEqual(BrowsingHistoryStore(fileURL: file).entries.count, 1)
    }

    func testDeletingProfileRemovesItsHistory() throws {
        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "gone", mode: .persistent)
        let store = BrowsingHistoryStore.store(for: profile, in: workspace)
        store.recordVisit(url("https://a.example.invalid/"), title: "A")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.historyURL(for: profile.id).path))
        workspace.removeRunnerArtifacts(for: profile.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.historyURL(for: profile.id).path))
    }

    func testSectionsSplitTodayAndEarlierNewestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 15)))
        func entry(_ title: String, hoursAgo: Double) -> BrowsingHistoryEntry {
            BrowsingHistoryEntry(url: url("https://\(title).example.invalid/"), title: title, visitedAt: now.addingTimeInterval(-hoursAgo * 3600))
        }
        let entries = [entry("lastYear", hoursAgo: 24 * 400), entry("morning", hoursAgo: 6), entry("yesterday", hoursAgo: 20), entry("justNow", hoursAgo: 0.1)]
        let sections = BrowsingHistoryStore.sections(for: entries, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.title), ["今天", "更早"])
        XCTAssertEqual(sections[0].entries.map(\.title), ["justNow", "morning"])
        XCTAssertEqual(sections[1].entries.map(\.title), ["yesterday", "lastYear"])
        XCTAssertEqual(BrowsingHistoryStore.sections(for: [entries[0]], now: now, calendar: calendar).map(\.title), ["更早"], "空组不显示")
        XCTAssertEqual(BrowsingHistoryStore.sections(for: [], now: now, calendar: calendar), [])
    }
}
