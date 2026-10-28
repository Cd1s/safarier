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

    // MARK: - 中日韩字体分组

    func testDefaultRootsAreSystemVolumeOnly() {
        let roots = FontAllowlistPlanner.defaultRoots
        XCTAssertFalse(roots.contains("/Library/Fonts"), "/Library/Fonts 是用户 / 第三方软件装的字体")
        XCTAssertFalse(roots.contains(NSHomeDirectory() + "/Library/Fonts"))
        XCTAssertTrue(roots.allSatisfy { $0.hasPrefix("/System/") }, "\(roots)")
    }

    func testCJKGroupMatchesKnownNamesBeforeLanguageFallback() {
        func group(_ names: Set<String>, family: String? = nil, languages: [String] = []) -> CJKFontGroup? {
            CJKFontGroup.classify(family: family ?? names.first, names: names) { languages }
        }
        XCTAssertEqual(group(["Hiragino Sans GB", "冬青黑體簡體中文"]), .chinese, "冬青黑体是中文字体，不能按 Hiragino Sans 前缀算成日文")
        XCTAssertEqual(group(["Hiragino Sans"]), .japanese)
        XCTAssertEqual(group(["Hiragino Kaku Gothic ProN"]), .japanese)
        for chinese in ["STHeiti", "Heiti SC", "Songti TC", "STSong", "Kaiti SC", "STFangsong", "PingFang HK", "Lantinghei SC", "Wawati TC",
                        "Apple LiGothic", "BiauKaiTC", "SimSun", "Microsoft YaHei", "PMingLiU", "DFKai-SB", "Hei", "Kai"] {
            XCTAssertEqual(group([chinese]), .chinese, chinese)
        }
        for japanese in ["YuGothic", "Yu Mincho", "Klee", "Osaka", "Toppan Bunkyu Mincho", "Tsukushi A Round Gothic", "BIZ UDGothic"] {
            XCTAssertEqual(group([japanese]), .japanese, japanese)
        }
        for korean in ["Apple SD Gothic Neo", "AppleMyungjo", "AppleGothic", "Nanum Gothic", "PilGi", "GungSeo", "HeadLineA", "PCMyungjo"] {
            XCTAssertEqual(group([korean]), .korean, korean)
        }
        // 名字相近的非中日韩字体不能误伤。
        for latin in ["Kailasa", "Noto Sans Kaithi", "Noto Sans Gothic", "Helvetica", "Hoefler Text"] {
            XCTAssertNil(group([latin], languages: ["en", "fr"]), latin)
        }
    }

    func testCJKGroupFallsBackToSupportedLanguagesButSparesPanUnicodeAndHiddenFonts() {
        XCTAssertEqual(CJKFontGroup.classify(family: "BM Jua", names: ["BM Jua"]) { ["en", "ko"] }, .korean)
        XCTAssertEqual(CJKFontGroup.classify(family: "Unknown Mincho", names: ["Unknown Mincho"]) { ["en", "ja"] }, .japanese)
        XCTAssertEqual(CJKFontGroup.classify(family: "GB18030 Bitmap", names: ["GB18030 Bitmap"]) { ["zh-Hans"] }, .chinese)
        XCTAssertEqual(CJKFontGroup.classify(family: "Unknown Hei", names: ["Unknown Hei"]) { ["ja", "zh-Hant"] }, .chinese, "中文和日文都支持时算中文")
        XCTAssertNil(CJKFontGroup.classify(family: "Arial Unicode MS", names: ["Arial Unicode MS"]) { ["ar", "he", "ja", "ko", "zh-Hans"] },
                     "泛 Unicode 字体不算中日韩字体")
        XCTAssertNil(CJKFontGroup.classify(family: ".PingFang SC", names: [".PingFang SC", "PingFangSC-Regular"]) { ["zh-Hans"] },
                     "系统界面字体网页按名字用不了，留着给系统回退")
        var asked = false
        _ = CJKFontGroup.classify(family: "Songti SC", names: ["Songti SC"]) { asked = true; return [] }
        XCTAssertFalse(asked, "名字匹配上就不读支持语言")
    }

    /// 真实的中、日、韩、泛 Unicode 字体文件（用符号链接放进假的系统目录，不复制大文件）：
    /// 每种语言只保留自己的中日韩字体，泛 Unicode 字体所有语言都保留。
    func testCJKSystemFontsFollowProfileLanguage() throws {
        let sources = [
            "chinese": "/System/Library/Fonts/Supplemental/Songti.ttc",
            "japanese": "/System/Library/Fonts/ヒラギノ明朝 ProN.ttc",
            "korean": "/System/Library/Fonts/Supplemental/AppleMyungjo.ttf",
            "pan": "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
            "latin": "/System/Library/Fonts/Supplemental/Ayuthaya.ttf",
        ]
        for path in sources.values where !FileManager.default.fileExists(atPath: path) { throw XCTSkip("本机没有 \(path)") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("FontAllowlistCJK-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let system = base.appendingPathComponent("system"), assets = base.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        var fonts: [String: FontNames] = [:]
        for (key, path) in sources {
            let link = system.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: path))
            fonts[key] = try names(of: link)
        }
        func kept(_ languages: [String]) -> Set<String> {
            let names = Set(FontAllowlistPlanner.plan(languages: languages, roots: [system.path], assetRoot: assets.path).names)
            return Set(fonts.filter { $0.value.families.isSubset(of: names) }.keys)
        }
        XCTAssertEqual(kept(["en-US", "en"]), ["pan", "latin"])
        XCTAssertEqual(kept(["zh-CN"]), ["chinese", "pan", "latin"])
        XCTAssertEqual(kept(["zh-TW"]), ["chinese", "pan", "latin"])
        XCTAssertEqual(kept(["ja-JP"]), ["japanese", "pan", "latin"])
        XCTAssertEqual(kept(["ko-KR"]), ["korean", "pan", "latin"])
        XCTAssertEqual(kept(["en-US", "ja-JP"]), ["japanese", "pan", "latin"])

        // 被排除的字体连本地化名（宋體-簡）也不在白名单里，否则网页能用本地化名探测。
        let english = FontAllowlistPlanner.plan(languages: ["en-US"], roots: [system.path], assetRoot: assets.path)
        XCTAssertTrue(Set(english.names).isDisjoint(with: ["Songti SC", "STSong", "宋體-簡", "Hiragino Mincho ProN", "AppleMyungjo"]))
        XCTAssertTrue(Set(english.excludedFamilies).isSuperset(of: fonts["chinese"]!.families.union(fonts["japanese"]!.families).union(fonts["korean"]!.families)))
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
    /// 系统卷上的中日韩字体（冬青黑体、华文黑体、宋体、平方、ヒラギノ、Apple SD Gothic Neo）英文环境不保留。
    func testHostEnglishPlanKeepsLatinSystemFontsAndDropsCJKSystemFonts() throws {
        let plan = hostPlan(["en-US"])
        XCTAssertFalse(plan.isNoOp, "每台 Mac 的系统卷上都有中日韩字体，英文环境一定要排除")
        let names = Set(plan.names)
        for expected in ["Times", "Courier", "Helvetica", "Menlo", "Thonburi", "Arial Unicode MS"] {
            XCTAssertTrue(names.contains(expected), "en-US 白名单缺少 \(expected)（共 \(plan.names.count) 个名字）")
        }
        for hidden in ["Heiti SC", "Heiti TC", "STHeiti", "Hiragino Sans GB", "HiraginoSansGB-W3", "冬青黑體簡體中文", "Songti SC", "STSong",
                       "宋體-簡", "Hiragino Sans", "Hiragino Mincho ProN", "Apple SD Gothic Neo", "AppleMyungjo"] {
            XCTAssertFalse(names.contains(hidden), "en-US 白名单不该有 \(hidden)")
        }
        XCTAssertTrue(Set(plan.excludedFamilies).isSuperset(of: ["Hiragino Sans GB", "Songti SC", "STSong", "Heiti SC", "Hiragino Sans", "Apple SD Gothic Neo"]),
                      "\(plan.excludedFamilies)")
    }

    func testHostPingFangAssetFollowsProfileLanguage() throws {
        guard Self.hostHasPingFangAsset else {
            throw XCTSkip("本机 \(FontAllowlistPlanner.defaultAssetRoot) 里没有 PingFang.ttc 资产")
        }
        let english = Set(hostPlan(["en-US"]).names)
        XCTAssertFalse(english.contains("PingFang SC"))
        XCTAssertFalse(english.contains("PingFangSC-Regular"))
        XCTAssertTrue(hostPlan(["en-US"]).excludedFamilies.contains("PingFang SC"), "\(hostPlan(["en-US"]).excludedFamilies)")

        // 中文环境保留苹方和系统中文字体，只排除日文、韩文专用字体。
        for languages in [["zh-CN"], ["zh-TW"]] {
            let plan = hostPlan(languages)
            let names = Set(plan.names)
            XCTAssertTrue(names.isSuperset(of: ["PingFang SC", "PingFang TC", "Hiragino Sans GB", "Songti SC"]), "\(languages)")
            XCTAssertTrue(names.isDisjoint(with: ["Hiragino Sans", "Apple SD Gothic Neo"]), "\(languages)")
            XCTAssertTrue(Set(plan.excludedFamilies).isDisjoint(with: ["PingFang SC", "Hiragino Sans GB", "Songti SC"]), "\(languages)：\(plan.excludedFamilies)")
        }

        XCTAssertFalse(Set(hostPlan(["th-TH"]).names).contains("PingFang SC"))
    }
}
