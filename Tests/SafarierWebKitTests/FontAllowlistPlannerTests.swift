import CoreText
import XCTest
@testable import SafarierWebKit

/// 字体白名单规划：语言 key、资产前提匹配（用拷贝出来的真实字体搭的假目录），以及本机真实字体目录上的回归。
final class FontAllowlistPlannerTests: XCTestCase {
    // MARK: - 语言 key

    func testLanguageKeysIncludeLanguageAndScript() {
        XCTAssertTrue(FontAllowlistPlanner.languageKeys(for: ["en-US"]).isSuperset(of: ["en"]))
        XCTAssertTrue(FontAllowlistPlanner.languageKeys(for: ["zh-CN"]).contains("zh-Hans"))
        XCTAssertTrue(FontAllowlistPlanner.languageKeys(for: ["zh-TW"]).contains("zh-Hant"))
        XCTAssertTrue(FontAllowlistPlanner.languageKeys(for: ["th-TH"]).contains("th"))
        // 简体环境不能被当成满足繁体前提，反之亦然。
        XCTAssertFalse(FontAllowlistPlanner.languageKeys(for: ["zh-CN"]).contains("zh-Hant"))
        XCTAssertFalse(FontAllowlistPlanner.languageKeys(for: ["zh-TW"]).contains("zh-Hans"))
    }

    // MARK: - 假目录

    /// 一个字体文件里全部字面的字族名和 PostScript 名（从文件读，不写死）。
    private struct FontNames {
        let families: Set<String>
        let postScriptNames: Set<String>
        var all: Set<String> { families.union(postScriptNames) }
    }

    private func names(of url: URL) throws -> FontNames {
        let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], url.path)
        XCTAssertFalse(descriptors.isEmpty, url.path)
        var families = Set<String>(), postScript = Set<String>()
        for descriptor in descriptors {
            if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String { families.insert(family) }
            if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String { postScript.insert(name) }
        }
        XCTAssertFalse(families.isEmpty, url.path)
        XCTAssertFalse(postScript.isEmpty, url.path)
        return FontNames(families: families, postScriptNames: postScript)
    }

    private struct Fixture {
        let systemDir: String
        let assetRoot: String
        let ayuthaya: FontNames
        let krungthep: FontNames
        let silom: FontNames

        func plan(_ languages: [String]) -> FontAllowlistPlan {
            FontAllowlistPlanner.plan(languages: languages, roots: [systemDir, assetRoot], assetRoot: assetRoot)
        }
    }

    /// system/Ayuthaya.ttf（系统字体）；assets/cjk.asset（前提是中日韩）/AssetData/Krungthep.ttf；
    /// assets/nopre.asset（没有前提）/AssetData/Silom.ttf。
    private func makeFixture() throws -> Fixture {
        let supplemental = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental")
        let sources = ["Ayuthaya.ttf", "Krungthep.ttf", "Silom.ttf"].map { supplemental.appendingPathComponent($0) }
        for source in sources where !FileManager.default.fileExists(atPath: source.path) {
            throw XCTSkip("本机没有 \(source.path)")
        }

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("FontAllowlistPlannerTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let system = base.appendingPathComponent("system")
        let assets = base.appendingPathComponent("assets")

        func makeAsset(_ name: String, properties: [String: Any], font: URL) throws -> URL {
            let dir = assets.appendingPathComponent(name)
            let data = dir.appendingPathComponent("AssetData")
            try fm.createDirectory(at: data, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["MobileAssetProperties": properties], format: .xml, options: 0)
            try plist.write(to: dir.appendingPathComponent("Info.plist"))
            let target = data.appendingPathComponent(font.lastPathComponent)
            try fm.copyItem(at: font, to: target)
            return target
        }

        try fm.createDirectory(at: system, withIntermediateDirectories: true)
        let ayuthaya = system.appendingPathComponent("Ayuthaya.ttf")
        try fm.copyItem(at: sources[0], to: ayuthaya)
        let krungthep = try makeAsset("cjk.asset", properties: ["Prerequisite": ["CJK", "ja", "ko", "zh-Hans", "zh-Hant"]], font: sources[1])
        let silom = try makeAsset("nopre.asset", properties: ["FontFamilies": ["Silom"]], font: sources[2])

        let fixture = Fixture(
            systemDir: system.path,
            assetRoot: assets.path,
            ayuthaya: try names(of: ayuthaya),
            krungthep: try names(of: krungthep),
            silom: try names(of: silom)
        )
        // 三个字体的名字互不重叠，下面"包含/不包含"的断言才有区分度。
        XCTAssertTrue(fixture.ayuthaya.all.isDisjoint(with: fixture.krungthep.all.union(fixture.silom.all)))
        XCTAssertTrue(fixture.krungthep.all.isDisjoint(with: fixture.silom.all))
        return fixture
    }

    func testEmptyLanguagesIsNoOp() throws {
        let fixture = try makeFixture()
        let plan = fixture.plan([])
        XCTAssertTrue(plan.isNoOp)
        XCTAssertEqual(plan.excludedFontCount, 0)
    }

    func testEnglishKeepsSystemFontAndDropsBothAssets() throws {
        let fixture = try makeFixture()
        let plan = fixture.plan(["en-US"])
        let names = Set(plan.names)
        XCTAssertFalse(plan.isNoOp)
        XCTAssertTrue(names.isSuperset(of: fixture.ayuthaya.all), "\(fixture.ayuthaya.all.subtracting(names))")
        XCTAssertTrue(names.isDisjoint(with: fixture.krungthep.all), "\(names.intersection(fixture.krungthep.all))")
        XCTAssertTrue(names.isDisjoint(with: fixture.silom.all), "\(names.intersection(fixture.silom.all))")
        XCTAssertTrue(Set(plan.excludedFamilies).isSuperset(of: fixture.krungthep.families.union(fixture.silom.families)), "\(plan.excludedFamilies)")
        XCTAssertTrue(Set(plan.excludedFamilies).isDisjoint(with: fixture.ayuthaya.families))
        XCTAssertEqual(plan.names, plan.names.sorted())
    }

    func testSimplifiedChineseKeepsAssetWhosePrerequisiteMatches() throws {
        let fixture = try makeFixture()
        let names = Set(fixture.plan(["zh-CN"]).names)
        XCTAssertTrue(names.isSuperset(of: fixture.ayuthaya.all))
        XCTAssertTrue(names.isSuperset(of: fixture.krungthep.all), "\(fixture.krungthep.all.subtracting(names))")
        // 没有前提的资产（用户按需下载）什么语言都不保留。
        XCTAssertTrue(names.isDisjoint(with: fixture.silom.all))
    }

    func testThaiKeepsOnlySystemFont() throws {
        let fixture = try makeFixture()
        let names = Set(fixture.plan(["th-TH"]).names)
        let everything = fixture.ayuthaya.all.union(fixture.krungthep.all).union(fixture.silom.all)
        XCTAssertEqual(names.intersection(everything), fixture.ayuthaya.all)
    }

    // MARK: - 系统卷基础字体

    func testDefaultRootsAreSystemVolumeOnly() {
        let roots = FontAllowlistPlanner.defaultRoots
        XCTAssertFalse(roots.contains("/Library/Fonts"), "/Library/Fonts 是用户 / 第三方软件装的字体")
        XCTAssertFalse(roots.contains(NSHomeDirectory() + "/Library/Fonts"))
        XCTAssertTrue(roots.allSatisfy { $0.hasPrefix("/System/") }, "\(roots)")
    }

    /// 真实的中、日、韩、泛 Unicode 字体文件（用符号链接放进假的系统目录，不复制大文件）：
    /// 系统卷基础字体的允许状态不随 Profile 语言改变；用一个必排除资产保证白名单实际生成。
    func testSystemCJKFontsAreKeptForEveryProfileLanguage() throws {
        let sources = [
            "chinese": "/System/Library/Fonts/Supplemental/Songti.ttc",
            "japanese": "/System/Library/Fonts/ヒラギノ明朝 ProN.ttc",
            "korean": "/System/Library/Fonts/Supplemental/AppleMyungjo.ttf",
            "pan": "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
            "latin": "/System/Library/Fonts/Supplemental/Ayuthaya.ttf",
        ]
        for path in sources.values where !FileManager.default.fileExists(atPath: path) { throw XCTSkip("本机没有 \(path)") }
        let fixture = try makeFixture()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("FontAllowlistCJK-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let system = base.appendingPathComponent("system"), assets = URL(fileURLWithPath: fixture.assetRoot)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        var fonts: [String: FontNames] = [:]
        for (key, path) in sources {
            let link = system.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: path))
            fonts[key] = try names(of: link)
        }
        func kept(_ languages: [String]) -> Set<String> {
            let names = Set(FontAllowlistPlanner.plan(languages: languages, roots: [system.path, assets.path], assetRoot: assets.path).names)
            return Set(fonts.filter { $0.value.families.isSubset(of: names) }.keys)
        }
        for languages in [["en-US", "en"], ["zh-CN"], ["zh-TW"], ["ja-JP"], ["ko-KR"], ["th-TH"]] {
            XCTAssertEqual(kept(languages), Set(sources.keys), "System fonts must survive: \(languages)")
        }
        let english = FontAllowlistPlanner.plan(languages: ["en-US"], roots: [system.path, assets.path], assetRoot: assets.path)
        XCTAssertTrue(Set(english.names).isSuperset(of: ["Songti SC", "STSong", "宋體-簡", "Hiragino Mincho ProN", "AppleMyungjo"]))
        XCTAssertTrue(Set(english.excludedFamilies).isDisjoint(with: fonts.values.reduce(into: Set<String>()) { $0.formUnion($1.families) }))
    }

    // MARK: - 本机真实字体

    private static let hostLock = NSLock()
    private static var hostPlans: [String: FontAllowlistPlan] = [:]

    /// 遍历本机全部字体要几秒，同一语言只算一次。
    private func hostPlan(_ languages: [String]) -> FontAllowlistPlan {
        let key = languages.joined(separator: ",")
        Self.hostLock.lock()
        defer { Self.hostLock.unlock() }
        if let cached = Self.hostPlans[key] { return cached }
        let plan = FontAllowlistPlanner.plan(languages: languages)
        Self.hostPlans[key] = plan
        return plan
    }

    static var hostHasPingFangAsset: Bool {
        let root = FontAllowlistPlanner.defaultAssetRoot
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return entries.contains { FileManager.default.fileExists(atPath: "\(root)/\($0)/AssetData/PingFang.ttc") }
    }

    /// 系统字体遍历要同时保留 Times / Courier 和基础 CJK 字体，不能把英文 Profile 当成“没有汉字字体”。
    func testHostEnglishPlanKeepsSystemFontsThatFontCollectionOmits() throws {
        let plan = hostPlan(["en-US"])
        try XCTSkipIf(plan.isNoOp, "Host has no non-English Font7 assets installed")
        let names = Set(plan.names)
        for expected in ["Times", "Courier", "Helvetica", "Menlo", "Thonburi", "Arial Unicode MS", "Hiragino Sans GB", "Songti SC", "Heiti SC", "Heiti TC", "STSong"] {
            XCTAssertTrue(names.contains(expected), "en-US 白名单缺少 \(expected)（共 \(plan.names.count) 个名字）")
        }
        for hidden in ["PingFang SC", "PingFang TC", "PingFang HK", "苹方-简", "Microsoft YaHei", "MiSans"] {
            XCTAssertFalse(names.contains(hidden), "en-US 白名单不该有额外资产或第三方字体 \(hidden)")
        }
        XCTAssertTrue(Set(plan.excludedFamilies).isDisjoint(with: ["Hiragino Sans GB", "Songti SC", "STSong", "Heiti SC", "Hiragino Sans", "Apple SD Gothic Neo"]))
    }

    func testHostPingFangAssetFollowsProfileLanguage() throws {
        guard Self.hostHasPingFangAsset else {
            throw XCTSkip("本机 \(FontAllowlistPlanner.defaultAssetRoot) 里没有 PingFang.ttc 资产")
        }
        let english = Set(hostPlan(["en-US"]).names)
        XCTAssertFalse(english.contains("PingFang SC"))
        XCTAssertFalse(english.contains("PingFangSC-Regular"))
        XCTAssertTrue(hostPlan(["en-US"]).excludedFamilies.contains("PingFang SC"), "\(hostPlan(["en-US"]).excludedFamilies)")

        // 中文环境保留苹方，所有语言的系统卷基础字体都保留。
        for languages in [["zh-CN"], ["zh-TW"]] {
            let plan = hostPlan(languages)
            if plan.isNoOp {
                XCTAssertEqual(plan.excludedFontCount, 0, "No allowlist is needed when all installed assets match")
                continue
            }
            let names = Set(plan.names)
            XCTAssertTrue(names.isSuperset(of: ["PingFang SC", "PingFang TC", "Hiragino Sans GB", "Songti SC"]), "\(languages)")
            XCTAssertTrue(names.isSuperset(of: ["Hiragino Sans", "Apple SD Gothic Neo"]), "\(languages)")
            XCTAssertTrue(Set(plan.excludedFamilies).isDisjoint(with: ["PingFang SC", "Hiragino Sans GB", "Songti SC"]), "\(languages)：\(plan.excludedFamilies)")
        }

        XCTAssertFalse(Set(hostPlan(["th-TH"]).names).contains("PingFang SC"))
    }
}
