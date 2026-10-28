import CoreText
import Foundation

/// 按 Profile 语言算出的字体白名单（交给 原生引擎桥接）。
public struct FontAllowlistPlan: Equatable, Sendable {
    /// 网页能按名字使用的字体名（字族名、PostScript 名、全名等）。空表示不设置白名单，行为和现在一样。
    public let names: [String]
    /// 被排除的字族（排序后）。
    public let excludedFamilies: [String]
    /// 被排除的字面数。
    public let excludedFontCount: Int
    /// 同时属于保留字体和排除字体的名字个数；保守起见这些名字也不进白名单。
    public let sharedNamesDropped: Int

    public init(names: [String], excludedFamilies: [String], excludedFontCount: Int, sharedNamesDropped: Int) {
        self.names = names
        self.excludedFamilies = excludedFamilies
        self.excludedFontCount = excludedFontCount
        self.sharedNamesDropped = sharedNamesDropped
    }

    /// 没有要排除的字体：不设置白名单。
    public var isNoOp: Bool { names.isEmpty }

    static let noOp = FontAllowlistPlan(names: [], excludedFamilies: [], excludedFontCount: 0, sharedNamesDropped: 0)
}

/// 字体白名单规划：
/// - 只遍历系统自带的字体目录。/Library/Fonts 和 ~/Library/Fonts 里是用户或第三方软件装的字体（Office 的宋体、雅黑…），
///   真 Safari 不给网页用，白名单也不收；
/// - 宿主机按语言从 Apple 下载的字体资产（AssetsV2 Font7，例如中日韩语言下载的苹方）只在 Profile 语言满足资产安装前提时保留；
/// - 中日韩字体（不论装在哪个系统目录）只在 Profile 语言里有这门语言时保留，见 `CJKFontGroup`。
///   否则英文环境的网页用 Canvas 宽度探测能测出冬青黑体、华文宋体，以及经 WebKit 别名映射到宋体的 SimSun。
///
/// 直接遍历字体文件取全部字面：`CTFontCollectionCreateFromAvailableFonts` 会漏掉 Times、Courier 等
/// 能按名字解析的字体，用它生成白名单会把这些常用字体也挡掉。
public enum FontAllowlistPlanner {
    /// 按需下载的字体资产目录，每个 `.asset` 子目录的 Info.plist 里有安装前提（Prerequisite）。
    public static let defaultAssetRoot = "/System/Library/AssetsV2/com_apple_MobileAsset_Font7"

    /// 遍历字体文件的根目录：只有系统卷上的字体。不在这里的字体不进白名单，网页按名字查不到。
    public static var defaultRoots: [String] {
        [
            "/System/Library/Fonts",
            "/System/Library/PrivateFrameworks/FontServices.framework/Resources",
            defaultAssetRoot,
        ]
    }

    /// Profile 语言标签 → 与资产前提比对用的 key：语言码（ja、ko、th…）和"语言码-文字"（zh-Hans、zh-Hant…）。
    public static func languageKeys(for tags: [String]) -> Set<String> {
        LanguageMatcher.keys(for: tags)
    }

    /// languages 为空（跟随系统）或没有需要排除的资产字体时返回空计划（不设置白名单）。
    public static func plan(languages: [String], roots: [String] = defaultRoots, assetRoot: String = defaultAssetRoot) -> FontAllowlistPlan {
        guard !languages.isEmpty else { return .noOp }
        let keys = LanguageMatcher.keys(for: languages)
        let catalog = FontAssetCatalog.load(root: assetRoot)
        var keep = Set<String>(), drop = Set<String>(), dropFamilies = Set<String>(), dropCount = 0
        for descriptor in fontDescriptorsFromFiles(roots: roots) {
            guard let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL else { continue }
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            var names = nameTableNames(font)
            for key in [kCTFontFamilyNameAttribute, kCTFontNameAttribute, kCTFontDisplayNameAttribute] {
                if let value = CTFontDescriptorCopyAttribute(descriptor, key) as? String { names.insert(value) }
            }
            // 资产字体：有前提且 Profile 语言满足前提才保留；没有前提的资产（用户按需下载）一律排除。
            let assetAllowed = catalog.asset(containing: url.path).map {
                !$0.prerequisites.isEmpty && LanguageMatcher.profile(keys, satisfies: $0.prerequisites)
            } ?? true
            // 中日韩字体：Profile 语言里没有这门语言就排除。
            let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
            let group = CJKFontGroup.classify(family: family, names: names) { CTFontCopySupportedLanguages(font) as? [String] ?? [] }
            let languageAllowed = group.map { !keys.isDisjoint(with: $0.languageKeys) } ?? true
            if assetAllowed && languageAllowed {
                keep.formUnion(names)
            } else {
                drop.formUnion(names)
                dropCount += 1
                if let family { dropFamilies.insert(family) }
            }
        }
        guard dropCount > 0 else { return .noOp }
        return FontAllowlistPlan(
            names: keep.subtracting(drop).sorted(),
            excludedFamilies: dropFamilies.sorted(),
            excludedFontCount: dropCount,
            sharedNamesDropped: keep.intersection(drop).count
        )
    }

    /// 遍历 roots 下的字体文件，取出全部字面描述符，并补上文件 URL（文件里读出的描述符没有 URL 属性，资产判断要用）。
    static func fontDescriptorsFromFiles(roots: [String]) -> [CTFontDescriptor] {
        let extensions: Set<String> = ["ttf", "ttc", "otf", "otc", "dfont"]
        var out: [CTFontDescriptor] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(atPath: root) else { continue }
            for case let relative as String in enumerator where extensions.contains((relative as NSString).pathExtension.lowercased()) {
                let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
                let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
                out += descriptors.map {
                    CTFontDescriptorCreateCopyWithAttributes($0, [kCTFontURLAttribute: url] as CFDictionary)
                }
            }
        }
        return out
    }
}

/// 中日韩字体按语言分组。Profile 语言里没有这门语言时，这组字体不进白名单。
///
/// 先按字族名、全名、PostScript 名（含本地化名）匹配已知字体；都没匹配上再看 CoreText 报的支持语言，
/// 只支持中日韩、不支持阿拉伯文 / 希伯来文的才算（Arial Unicode MS、LastResort 这类泛 Unicode 字体不算）。
/// 字族名以 "." 开头的系统界面字体（.PingFang SC、.Aqua Kana…）网页本来就按名字用不了，不归组，留着给系统回退。
public enum CJKFontGroup: String, Sendable {
    case chinese, japanese, korean

    /// Profile 语言 key 里有其中之一，这组字体才保留。
    public var languageKeys: Set<String> {
        switch self {
        case .chinese: ["zh", "zh-Hans", "zh-Hant"]
        case .japanese: ["ja"]
        case .korean: ["ko"]
        }
    }

    /// 名字去掉空格、连字符、下划线并转小写后的前缀。中文先匹配：Hiragino Sans GB 是中文字体，Hiragino Sans 是日文字体。
    static let chinesePrefixes = [
        "hiraginosansgb", "hiraginosanstc", "hiraginosanscns", "stheiti", "stxihei", "heitisc", "heititc", "songti", "stsong", "simsong",
        "kaiti", "stkaiti", "stfangsong", "fangsong", "baoli", "hanzipen", "hannotate", "lantinghei", "libian", "lingwai", "pingfang",
        "wawa", "weibei", "xingkai", "yuanti", "yuppy", "appleligothic", "applelisung", "lihei", "lisong", "biaukai", "simsun", "nsimsun",
        "simhei", "microsoftyahei", "microsoftjhenghei", "pmingliu", "mingliu", "dfkai", "dengxian", "gb18030", "sourcehansanscn",
        "sourcehansanssc", "sourcehansanstw", "sourcehansanshk", "notosanscjksc", "notosanscjktc", "notoserifcjksc", "notoserifcjktc",
        "wenquanyi",
    ]
    /// 整个名字就是这些（太短，按前缀会误伤）。
    static let chineseExactNames: Set<String> = ["hei", "kai"]
    static let japanesePrefixes = [
        "hiraginokaku", "hiraginomaru", "hiraginomincho", "hiraginosans", "klee", "osaka", "toppanbunkyu", "tsukushi", "yugothic",
        "yumincho", "yukyokasho", "bizud", "msgothic", "mspgothic", "msmincho", "mspmincho", "meiryo", "notosanscjkjp", "sourcehansansjp",
    ]
    static let koreanPrefixes = [
        "applemyungjo", "applesdgothicneo", "applegothic", "gungseo", "headlinea", "nanum", "pcmyungjo", "pilgi", "malgungothic",
        "gulim", "dotum", "batang", "gungsuh", "notosanscjkkr", "sourcehansanskr",
    ]

    /// nil：不是中日韩专用字体（或是不能按名字用的系统界面字体）。`supportedLanguages` 只在名字没匹配上时才读。
    public static func classify(family: String?, names: Set<String>, supportedLanguages: () -> [String]) -> CJKFontGroup? {
        if family?.hasPrefix(".") == true { return nil }
        let normalized = names.filter { !$0.hasPrefix(".") }.map { $0.lowercased().filter { !" -_".contains($0) } }
        func matches(_ prefixes: [String]) -> Bool { normalized.contains { name in prefixes.contains { name.hasPrefix($0) } } }
        if matches(chinesePrefixes) || normalized.contains(where: chineseExactNames.contains) { return .chinese }
        if matches(japanesePrefixes) { return .japanese }
        if matches(koreanPrefixes) { return .korean }

        let languages = supportedLanguages()
        if languages.contains(where: { $0 == "ar" || $0 == "he" || $0.hasPrefix("ar-") || $0.hasPrefix("he-") }) { return nil }
        if languages.contains(where: { $0 == "zh" || $0.hasPrefix("zh-") }) { return .chinese }
        if languages.contains("ja") { return .japanese }
        if languages.contains("ko") { return .korean }
        return nil
    }
}

/// 本机已安装的 AssetsV2 Font7 资产：字体文件所在目录 → 安装前提语言（Info.plist 的 Prerequisite）。
struct FontAssetCatalog {
    struct Asset {
        let directory: String
        let prerequisites: [String]
    }

    let assets: [Asset]

    static func load(root: String = FontAllowlistPlanner.defaultAssetRoot) -> FontAssetCatalog {
        let directories = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        var list: [Asset] = []
        for name in directories where name.hasSuffix(".asset") {
            let path = "\(root)/\(name)"
            guard let data = FileManager.default.contents(atPath: "\(path)/Info.plist"),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            let properties = plist["MobileAssetProperties"] as? [String: Any] ?? plist
            list.append(Asset(directory: path, prerequisites: properties["Prerequisite"] as? [String] ?? []))
        }
        return FontAssetCatalog(assets: list)
    }

    /// nil：不在任何 Font7 资产里（系统卷上的其它字体）。
    func asset(containing fontPath: String) -> Asset? {
        let resolved = (fontPath as NSString).resolvingSymlinksInPath
        return assets.first { resolved.hasPrefix($0.directory + "/") || fontPath.hasPrefix($0.directory + "/") }
    }
}

/// Profile 语言和资产前提的匹配：前提里的小写 token 是语言（ja、ko、zh-Hans、zh-Hant、th、hi…），
/// 大写的是分组名（CJK、THAI），不会和语言 key 相等。
enum LanguageMatcher {
    static func keys(for tags: [String]) -> Set<String> {
        var out = Set<String>()
        for tag in tags {
            let language = Locale.Language(identifier: tag)
            guard let code = language.languageCode?.identifier else { continue }
            out.insert(code)
            let script = language.script?.identifier
                ?? Locale.Language(identifier: language.maximalIdentifier).script?.identifier
            if let script { out.insert("\(code)-\(script)") }
        }
        return out
    }

    static func profile(_ keys: Set<String>, satisfies prerequisites: [String]) -> Bool {
        prerequisites.contains { keys.contains($0) }
    }
}

/// 读字体 name 表里的字族名（1）、全名（4）、PostScript 名（6）、首选字族名（16）、WWS 字族名（21），含各语言的本地化名。
func nameTableNames(_ font: CTFont) -> Set<String> {
    var out = Set<String>()
    guard let data = CTFontCopyTable(font, CTFontTableTag(kCTFontTableName), []) as Data?, data.count >= 6 else { return out }
    let bytes = [UInt8](data)
    func u16(_ index: Int) -> Int { index + 1 < bytes.count ? Int(bytes[index]) << 8 | Int(bytes[index + 1]) : 0 }
    let storage = u16(4)
    for record in 0..<u16(2) {
        let offset = 6 + record * 12
        guard offset + 12 <= bytes.count else { break }
        let platform = u16(offset), encoding = u16(offset + 2), nameID = u16(offset + 6)
        let length = u16(offset + 8), stringOffset = u16(offset + 10)
        guard [1, 4, 6, 16, 21].contains(nameID), storage + stringOffset + length <= bytes.count else { continue }
        let raw = Data(bytes[(storage + stringOffset)..<(storage + stringOffset + length)])
        var value: String?
        if platform == 0 || platform == 3 {
            value = String(data: raw, encoding: .utf16BigEndian)
        } else if platform == 1 {
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding))
            value = String(data: raw, encoding: String.Encoding(rawValue: nsEncoding))
        }
        if let value, !value.isEmpty { out.insert(value) }
    }
    return out
}
