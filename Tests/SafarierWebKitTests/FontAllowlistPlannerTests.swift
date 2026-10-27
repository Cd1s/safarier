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

    /// 回归：用 CTFontCollection 生成白名单时漏掉了 Times、Courier 等能按名字解析的字体。
    func testHostEnglishPlanKeepsSystemFontsThatFontCollectionOmits() {
        let plan = hostPlan(["en-US"])
        let names = Set(plan.names)
        for expected in ["Times", "Courier", "Heiti SC", "Hiragino Sans GB", "HiraginoSansGB-W3", "冬青黑体简体中文", "Songti SC", "Thonburi"] {
            XCTAssertTrue(names.contains(expected), "en-US 白名单缺少 \(expected)（共 \(plan.names.count) 个名字）")
        }
    }

    func testHostPingFangAssetFollowsProfileLanguage() throws {
        guard Self.hostHasPingFangAsset else {
            throw XCTSkip("本机 \(FontAllowlistPlanner.defaultAssetRoot) 里没有 PingFang.ttc 资产")
        }
        let english = Set(hostPlan(["en-US"]).names)
        XCTAssertFalse(english.contains("PingFang SC"))
        XCTAssertFalse(english.contains("PingFangSC-Regular"))
        XCTAssertTrue(hostPlan(["en-US"]).excludedFamilies.contains("PingFang SC"), "\(hostPlan(["en-US"]).excludedFamilies)")

        let simplified = hostPlan(["zh-CN"])
        XCTAssertTrue(simplified.isNoOp, "zh-CN 排除了 \(simplified.excludedFamilies)")
        let traditional = hostPlan(["zh-TW"])
        XCTAssertTrue(traditional.isNoOp, "zh-TW 排除了 \(traditional.excludedFamilies)")

        XCTAssertFalse(Set(hostPlan(["th-TH"]).names).contains("PingFang SC"))
    }
}
