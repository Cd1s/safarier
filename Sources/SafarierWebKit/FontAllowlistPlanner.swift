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

/// 字体白名单规划按来源和字体资产的语言安装前提过滤，不按字体覆盖的文字分类。
/// - 系统卷基础字体（含 Supplemental）在所有 Profile 中保留；英文 macOS 也自带部分 CJK 字体。
/// - AssetsV2 `com_apple_MobileAsset_Font*`（macOS 15 及以前是 Font7，macOS 26 起是 Font8）按需资产只在 Profile 满足安装前提时保留；没有前提的额外下载资产不保留。
/// - 不扫描 /Library/Fonts 或 ~/Library/Fonts，第三方和用户字体不加入允许集合。
///
/// 直接遍历字体文件取全部字面：`CTFontCollectionCreateFromAvailableFonts` 会漏掉 Times、Courier 等
/// 能按名字解析的字体，用它生成白名单会把这些常用字体也挡掉。
public enum FontAllowlistPlanner {
    /// 按需下载的字体资产所在的父目录；其下每个 `com_apple_MobileAsset_Font*` 是一代资产目录。
    public static let assetsV2Directory = "/System/Library/AssetsV2"
    static let assetRootPrefix = "com_apple_MobileAsset_Font"

    /// 本机全部字体资产目录（Font7、Font8……按名字排序）。Apple 每隔几代会换一个版本号，不写死。
    public static var defaultAssetRoots: [String] { discoverAssetRoots(in: assetsV2Directory) }

    /// 列出 `directory` 下名字以 `com_apple_MobileAsset_Font` 开头的子目录（不跟随普通文件）。
    static func discoverAssetRoots(in directory: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return entries
            .filter { $0.hasPrefix(assetRootPrefix) }
            .sorted()
            .map { "\(directory)/\($0)" }
            .filter { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
    }

    /// 遍历字体文件的根目录：只有系统卷上的字体。不在这里的字体不进白名单，网页按名字查不到。
    public static var defaultRoots: [String] {
        [
            "/System/Library/Fonts",
            "/System/Library/PrivateFrameworks/FontServices.framework/Resources",
        ] + defaultAssetRoots
    }

    /// Profile 语言标签 → 与资产前提比对用的 key：语言码（ja、ko、th…）和"语言码-文字"（zh-Hans、zh-Hant…）。
    public static func languageKeys(for tags: [String]) -> Set<String> {
        LanguageMatcher.keys(for: tags)
    }

    /// languages 为空（跟随系统）或没有需要排除的资产字体时返回空计划（不设置白名单）。
    public static func plan(languages: [String], roots: [String] = defaultRoots, assetRoots: [String] = defaultAssetRoots) -> FontAllowlistPlan {
        guard !languages.isEmpty else { return .noOp }
        let keys = LanguageMatcher.keys(for: languages)
        let catalog = FontAssetCatalog.load(roots: assetRoots)
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
            let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
            if assetAllowed {
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

/// 本机已安装的 AssetsV2 字体资产（Font7、Font8……）：字体文件所在目录 → 安装前提语言。
/// 前提取 Info.plist 的 `Prerequisite`；没有这个键时退回 `FontDesignLanguages`（资产设计面向的语言）。
struct FontAssetCatalog {
    struct Asset {
        let directory: String
        let prerequisites: [String]
    }

    let assets: [Asset]

    static func load(roots: [String] = FontAllowlistPlanner.defaultAssetRoots) -> FontAssetCatalog {
        var list: [Asset] = []
        for root in roots {
            let directories = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for name in directories.sorted() where name.hasSuffix(".asset") {
                let path = "\(root)/\(name)"
                guard let data = FileManager.default.contents(atPath: "\(path)/Info.plist"),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }
                let properties = plist["MobileAssetProperties"] as? [String: Any] ?? plist
                let prerequisites = properties["Prerequisite"] as? [String] ?? []
                let designLanguages = properties["FontDesignLanguages"] as? [String] ?? []
                list.append(Asset(directory: path, prerequisites: prerequisites.isEmpty ? designLanguages : prerequisites))
            }
        }
        return FontAssetCatalog(assets: list)
    }

    /// nil：不在任何字体资产里（系统卷上的其它字体）。
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
