import Foundation
import SafarierCore

/// 一个国家/地区对应的浏览器语言和时区。
public struct CountryLocale: Equatable, Sendable {
    public let name: String
    /// BCP-47，首选在前，可直接作为 `-AppleLanguages`。
    public let languages: [String]
    /// IANA 时区；多时区的国家取首都或人口最多的城市。
    public let timeZoneIdentifier: String
}

/// 常见国家/地区（ISO 3166-1 alpha-2）→ 语言和时区。语言来自 Unicode CLDR 48 的人口数据，
/// 部分按浏览器实际使用习惯调整（例如印度、菲律宾用 en，香港 zh-HK + en）；时区来自 IANA tzdata 2026c。
public enum CountryLocaleTable {
    public static let entries: [String: CountryLocale] = [
        "US": CountryLocale(name: "United States", languages: ["en-US", "en"], timeZoneIdentifier: "America/Los_Angeles"),
        "CA": CountryLocale(name: "Canada", languages: ["en-CA", "en", "fr"], timeZoneIdentifier: "America/Toronto"),
        "MX": CountryLocale(name: "Mexico", languages: ["es-MX", "es"], timeZoneIdentifier: "America/Mexico_City"),
        "BR": CountryLocale(name: "Brazil", languages: ["pt-BR", "pt"], timeZoneIdentifier: "America/Sao_Paulo"),
        "AR": CountryLocale(name: "Argentina", languages: ["es-AR", "es"], timeZoneIdentifier: "America/Argentina/Buenos_Aires"),
        "CL": CountryLocale(name: "Chile", languages: ["es-CL", "es"], timeZoneIdentifier: "America/Santiago"),
        "CO": CountryLocale(name: "Colombia", languages: ["es-CO", "es"], timeZoneIdentifier: "America/Bogota"),
        "PE": CountryLocale(name: "Peru", languages: ["es-PE", "es"], timeZoneIdentifier: "America/Lima"),
        "GB": CountryLocale(name: "United Kingdom", languages: ["en-GB", "en"], timeZoneIdentifier: "Europe/London"),
        "IE": CountryLocale(name: "Ireland", languages: ["en-IE", "en"], timeZoneIdentifier: "Europe/Dublin"),
        "FR": CountryLocale(name: "France", languages: ["fr-FR", "fr"], timeZoneIdentifier: "Europe/Paris"),
        "DE": CountryLocale(name: "Germany", languages: ["de-DE", "de"], timeZoneIdentifier: "Europe/Berlin"),
        "AT": CountryLocale(name: "Austria", languages: ["de-AT", "de"], timeZoneIdentifier: "Europe/Vienna"),
        "CH": CountryLocale(name: "Switzerland", languages: ["de-CH", "de", "fr"], timeZoneIdentifier: "Europe/Zurich"),
        "NL": CountryLocale(name: "Netherlands", languages: ["nl-NL", "nl"], timeZoneIdentifier: "Europe/Amsterdam"),
        "BE": CountryLocale(name: "Belgium", languages: ["nl-BE", "nl", "fr"], timeZoneIdentifier: "Europe/Brussels"),
        "LU": CountryLocale(name: "Luxembourg", languages: ["fr-LU", "fr", "de"], timeZoneIdentifier: "Europe/Luxembourg"),
        "ES": CountryLocale(name: "Spain", languages: ["es-ES", "es"], timeZoneIdentifier: "Europe/Madrid"),
        "PT": CountryLocale(name: "Portugal", languages: ["pt-PT", "pt"], timeZoneIdentifier: "Europe/Lisbon"),
        "IT": CountryLocale(name: "Italy", languages: ["it-IT", "it"], timeZoneIdentifier: "Europe/Rome"),
        "SE": CountryLocale(name: "Sweden", languages: ["sv-SE", "sv"], timeZoneIdentifier: "Europe/Stockholm"),
        "NO": CountryLocale(name: "Norway", languages: ["nb-NO", "nb"], timeZoneIdentifier: "Europe/Oslo"),
        "DK": CountryLocale(name: "Denmark", languages: ["da-DK", "da"], timeZoneIdentifier: "Europe/Copenhagen"),
        "FI": CountryLocale(name: "Finland", languages: ["fi-FI", "fi"], timeZoneIdentifier: "Europe/Helsinki"),
        "IS": CountryLocale(name: "Iceland", languages: ["is-IS", "is"], timeZoneIdentifier: "Atlantic/Reykjavik"),
        "PL": CountryLocale(name: "Poland", languages: ["pl-PL", "pl"], timeZoneIdentifier: "Europe/Warsaw"),
        "CZ": CountryLocale(name: "Czechia", languages: ["cs-CZ", "cs"], timeZoneIdentifier: "Europe/Prague"),
        "SK": CountryLocale(name: "Slovakia", languages: ["sk-SK", "sk"], timeZoneIdentifier: "Europe/Bratislava"),
        "HU": CountryLocale(name: "Hungary", languages: ["hu-HU", "hu"], timeZoneIdentifier: "Europe/Budapest"),
        "RO": CountryLocale(name: "Romania", languages: ["ro-RO", "ro"], timeZoneIdentifier: "Europe/Bucharest"),
        "BG": CountryLocale(name: "Bulgaria", languages: ["bg-BG", "bg"], timeZoneIdentifier: "Europe/Sofia"),
        "GR": CountryLocale(name: "Greece", languages: ["el-GR", "el"], timeZoneIdentifier: "Europe/Athens"),
        "TR": CountryLocale(name: "Türkiye", languages: ["tr-TR", "tr"], timeZoneIdentifier: "Europe/Istanbul"),
        "UA": CountryLocale(name: "Ukraine", languages: ["uk-UA", "uk"], timeZoneIdentifier: "Europe/Kyiv"),
        "RU": CountryLocale(name: "Russian Federation", languages: ["ru-RU", "ru"], timeZoneIdentifier: "Europe/Moscow"),
        "IL": CountryLocale(name: "Israel", languages: ["he-IL", "he"], timeZoneIdentifier: "Asia/Jerusalem"),
        "AE": CountryLocale(name: "United Arab Emirates", languages: ["ar-AE", "ar"], timeZoneIdentifier: "Asia/Dubai"),
        "SA": CountryLocale(name: "Saudi Arabia", languages: ["ar-SA", "ar"], timeZoneIdentifier: "Asia/Riyadh"),
        "QA": CountryLocale(name: "Qatar", languages: ["ar-QA", "ar"], timeZoneIdentifier: "Asia/Qatar"),
        "KW": CountryLocale(name: "Kuwait", languages: ["ar-KW", "ar"], timeZoneIdentifier: "Asia/Kuwait"),
        "BH": CountryLocale(name: "Bahrain", languages: ["ar-BH", "ar"], timeZoneIdentifier: "Asia/Bahrain"),
        "OM": CountryLocale(name: "Oman", languages: ["ar-OM", "ar"], timeZoneIdentifier: "Asia/Muscat"),
        "JO": CountryLocale(name: "Jordan", languages: ["ar-JO", "ar"], timeZoneIdentifier: "Asia/Amman"),
        "LB": CountryLocale(name: "Lebanon", languages: ["apc-LB", "apc"], timeZoneIdentifier: "Asia/Beirut"),
        "EG": CountryLocale(name: "Egypt", languages: ["ar-EG", "ar"], timeZoneIdentifier: "Africa/Cairo"),
        "ZA": CountryLocale(name: "South Africa", languages: ["en-ZA", "en"], timeZoneIdentifier: "Africa/Johannesburg"),
        "NG": CountryLocale(name: "Nigeria", languages: ["en-NG", "en"], timeZoneIdentifier: "Africa/Lagos"),
        "KE": CountryLocale(name: "Kenya", languages: ["en-KE", "en", "sw"], timeZoneIdentifier: "Africa/Nairobi"),
        "MA": CountryLocale(name: "Morocco", languages: ["ary-MA", "ary"], timeZoneIdentifier: "Africa/Casablanca"),
        "IN": CountryLocale(name: "India", languages: ["en-IN", "en", "hi"], timeZoneIdentifier: "Asia/Kolkata"),
        "PK": CountryLocale(name: "Pakistan", languages: ["en-PK", "en", "ur"], timeZoneIdentifier: "Asia/Karachi"),
        "BD": CountryLocale(name: "Bangladesh", languages: ["bn-BD", "bn"], timeZoneIdentifier: "Asia/Dhaka"),
        "LK": CountryLocale(name: "Sri Lanka", languages: ["si-LK", "si"], timeZoneIdentifier: "Asia/Colombo"),
        "NP": CountryLocale(name: "Nepal", languages: ["ne-NP", "ne"], timeZoneIdentifier: "Asia/Kathmandu"),
        "TH": CountryLocale(name: "Thailand", languages: ["th-TH", "th"], timeZoneIdentifier: "Asia/Bangkok"),
        "VN": CountryLocale(name: "Viet Nam", languages: ["vi-VN", "vi"], timeZoneIdentifier: "Asia/Ho_Chi_Minh"),
        "MY": CountryLocale(name: "Malaysia", languages: ["ms-MY", "ms", "en"], timeZoneIdentifier: "Asia/Kuala_Lumpur"),
        "SG": CountryLocale(name: "Singapore", languages: ["en-SG", "en"], timeZoneIdentifier: "Asia/Singapore"),
        "ID": CountryLocale(name: "Indonesia", languages: ["id-ID", "id"], timeZoneIdentifier: "Asia/Jakarta"),
        "PH": CountryLocale(name: "Philippines", languages: ["en-PH", "en"], timeZoneIdentifier: "Asia/Manila"),
        "KH": CountryLocale(name: "Cambodia", languages: ["km-KH", "km"], timeZoneIdentifier: "Asia/Phnom_Penh"),
        "MM": CountryLocale(name: "Myanmar", languages: ["my-MM", "my"], timeZoneIdentifier: "Asia/Yangon"),
        "LA": CountryLocale(name: "Lao People's Democratic Republic", languages: ["lo-LA", "lo"], timeZoneIdentifier: "Asia/Vientiane"),
        "CN": CountryLocale(name: "China", languages: ["zh-CN", "zh"], timeZoneIdentifier: "Asia/Shanghai"),
        "HK": CountryLocale(name: "Hong Kong", languages: ["zh-HK", "zh-Hant", "en"], timeZoneIdentifier: "Asia/Hong_Kong"),
        "MO": CountryLocale(name: "Macao", languages: ["zh-MO", "zh-Hant"], timeZoneIdentifier: "Asia/Macau"),
        "TW": CountryLocale(name: "Taiwan", languages: ["zh-TW", "zh-Hant"], timeZoneIdentifier: "Asia/Taipei"),
        "JP": CountryLocale(name: "Japan", languages: ["ja-JP", "ja"], timeZoneIdentifier: "Asia/Tokyo"),
        "KR": CountryLocale(name: "Korea, Republic of", languages: ["ko-KR", "ko"], timeZoneIdentifier: "Asia/Seoul"),
        "MN": CountryLocale(name: "Mongolia", languages: ["mn-MN", "mn"], timeZoneIdentifier: "Asia/Ulaanbaatar"),
        "AU": CountryLocale(name: "Australia", languages: ["en-AU", "en"], timeZoneIdentifier: "Australia/Sydney"),
        "NZ": CountryLocale(name: "New Zealand", languages: ["en-NZ", "en"], timeZoneIdentifier: "Pacific/Auckland"),
        "KZ": CountryLocale(name: "Kazakhstan", languages: ["ru-KZ", "ru"], timeZoneIdentifier: "Asia/Almaty"),
        "UZ": CountryLocale(name: "Uzbekistan", languages: ["uz-UZ", "uz"], timeZoneIdentifier: "Asia/Tashkent"),
        "HR": CountryLocale(name: "Croatia", languages: ["hr-HR", "hr"], timeZoneIdentifier: "Europe/Zagreb"),
        "SI": CountryLocale(name: "Slovenia", languages: ["sl-SI", "sl"], timeZoneIdentifier: "Europe/Ljubljana"),
        "RS": CountryLocale(name: "Serbia", languages: ["sr-RS", "sr"], timeZoneIdentifier: "Europe/Belgrade"),
        "EE": CountryLocale(name: "Estonia", languages: ["et-EE", "et"], timeZoneIdentifier: "Europe/Tallinn"),
        "LV": CountryLocale(name: "Latvia", languages: ["lv-LV", "lv"], timeZoneIdentifier: "Europe/Riga"),
        "LT": CountryLocale(name: "Lithuania", languages: ["lt-LT", "lt"], timeZoneIdentifier: "Europe/Vilnius"),
        "GE": CountryLocale(name: "Georgia", languages: ["ka-GE", "ka"], timeZoneIdentifier: "Asia/Tbilisi"),
        "AM": CountryLocale(name: "Armenia", languages: ["hy-AM", "hy"], timeZoneIdentifier: "Asia/Yerevan"),
        "AZ": CountryLocale(name: "Azerbaijan", languages: ["az-AZ", "az"], timeZoneIdentifier: "Asia/Baku"),
        "CY": CountryLocale(name: "Cyprus", languages: ["el-CY", "el"], timeZoneIdentifier: "Asia/Nicosia"),
        "MT": CountryLocale(name: "Malta", languages: ["mt-MT", "mt"], timeZoneIdentifier: "Europe/Malta"),
    ]

    /// 表里没有的国家用 CLDR likely subtags 推出主要语言（例如 EC → es），时区由调用方提供。
    public static func locale(for countryCode: String, fallbackTimeZone: String? = nil) -> CountryLocale? {
        let code = countryCode.uppercased()
        if let entry = entries[code] { return entry }
        guard code.count == 2, code.allSatisfy(\.isLetter), let timeZone = fallbackTimeZone, TimeZone(identifier: timeZone) != nil,
              let language = Locale.Language(identifier: "und-\(code)").maximalIdentifier.split(separator: "-").first.map(String.init),
              language != "und"
        else { return nil }
        return CountryLocale(name: code, languages: ["\(language)-\(code)", language], timeZoneIdentifier: timeZone)
    }
}

/// 跟随代理时解析出的语言和时区。
public struct ProxyGeoResult: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// 经代理请求 GeoIP 接口得到（参数是接口地址）。
        case lookup(String)
        /// 探测失败时按节点名 / 代理名里的国家线索推断。
        case nameHint
    }

    public let countryCode: String
    public let languages: [String]
    public let timeZoneIdentifier: String
    public let source: Source

    public init(countryCode: String, languages: [String], timeZoneIdentifier: String, source: Source) {
        self.countryCode = countryCode
        self.languages = languages
        self.timeZoneIdentifier = timeZoneIdentifier
        self.source = source
    }

    /// 语言跟随代理时 Runner 要带着新的 `-AppleLanguages` 重新启动自己；解析结果经环境变量带过去，
    /// 重新启动后直接用，不再探测一次（也不会再重启）。
    public static let relaunchFlag = "SAFARIER_GEO_RELAUNCHED"
    static let countryKey = "SAFARIER_GEO_COUNTRY", languagesKey = "SAFARIER_GEO_LANGUAGES"
    static let timeZoneKey = "SAFARIER_GEO_TIMEZONE", sourceKey = "SAFARIER_GEO_SOURCE"

    public var relaunchEnvironment: [String: String] {
        let sourceValue: String
        switch source {
        case .lookup(let url): sourceValue = "lookup:" + url
        case .nameHint: sourceValue = "name"
        }
        return [
            Self.relaunchFlag: "1", Self.countryKey: countryCode, Self.languagesKey: languages.joined(separator: ","),
            Self.timeZoneKey: timeZoneIdentifier, Self.sourceKey: sourceValue,
        ]
    }

    public init?(relaunchedFrom environment: [String: String]) {
        guard environment[Self.relaunchFlag] == "1",
              let country = environment[Self.countryKey], !country.isEmpty,
              let languages = environment[Self.languagesKey]?.split(separator: ",").map(String.init), !languages.isEmpty,
              let timeZone = environment[Self.timeZoneKey], TimeZone(identifier: timeZone) != nil
        else { return nil }
        let raw = environment[Self.sourceKey] ?? ""
        let source: Source = raw.hasPrefix("lookup:") ? .lookup(String(raw.dropFirst(7))) : .nameHint
        self.init(countryCode: country, languages: languages, timeZoneIdentifier: timeZone, source: source)
    }
}

/// 按代理的出口 IP 推断国家，再给出语言和时区。
///
/// 探测一律经代理（socks5h 让 DNS 也在代理那端解析），不会走直连；没有代理就不探测。
/// 依次请求 ipwho.is、api.ip.sb、Cloudflare trace，每个最多 `timeout` 秒，有一个成功就停。
/// 都失败时按节点名里的国家线索（国旗、国家/城市名、两字母代码）推断；还不行返回 nil，调用方沿用系统设置。
public enum ProxyGeoResolver {
    public enum EndpointKind: Sendable { case ipwhois, ipsb, cloudflareTrace }

    public static let endpoints: [(url: String, kind: EndpointKind)] = [
        ("https://ipwho.is/", .ipwhois),
        ("https://api.ip.sb/geoip", .ipsb),
        ("https://www.cloudflare.com/cdn-cgi/trace", .cloudflareTrace),
    ]

    /// 经代理取一个 URL 的正文；失败返回 nil。测试里替换成假的。
    public typealias Fetch = @Sendable (_ url: String, _ proxy: ProxySettings, _ password: String?, _ timeout: TimeInterval) -> String?

    public static func resolve(
        proxy: ProxySettings?,
        password: String?,
        nodeHint: String?,
        timeout: TimeInterval = 4,
        fetch: Fetch = curlFetch
    ) -> ProxyGeoResult? {
        if let proxy {
            for endpoint in endpoints {
                guard let body = fetch(endpoint.url, proxy, password, timeout),
                      let parsed = parse(body, kind: endpoint.kind),
                      let result = result(country: parsed.country, timeZone: parsed.timeZone, source: .lookup(endpoint.url))
                else { continue }
                return result
            }
        }
        for hint in [nodeHint, proxy?.name].compactMap({ $0 }) {
            if let code = inferCountry(from: hint), let result = result(country: code, timeZone: nil, source: .nameHint) {
                return result
            }
        }
        return nil
    }

    static func result(country: String, timeZone: String?, source: ProxyGeoResult.Source) -> ProxyGeoResult? {
        let validTimeZone = timeZone.flatMap { TimeZone(identifier: $0) != nil ? $0 : nil }
        guard let locale = CountryLocaleTable.locale(for: country, fallbackTimeZone: validTimeZone) else { return nil }
        return ProxyGeoResult(
            countryCode: country.uppercased(),
            languages: locale.languages,
            timeZoneIdentifier: validTimeZone ?? locale.timeZoneIdentifier,
            source: source
        )
    }

    /// 解析接口正文，得到国家代码和（可能有的）时区。
    public static func parse(_ body: String, kind: EndpointKind) -> (country: String, timeZone: String?)? {
        switch kind {
        case .ipwhois:
            guard let json = jsonObject(body), (json["success"] as? Bool) != false,
                  let country = json["country_code"] as? String, country.count == 2 else { return nil }
            return (country.uppercased(), (json["timezone"] as? [String: Any])?["id"] as? String)
        case .ipsb:
            guard let json = jsonObject(body), let country = json["country_code"] as? String, country.count == 2 else { return nil }
            return (country.uppercased(), json["timezone"] as? String)
        case .cloudflareTrace:
            for line in body.split(whereSeparator: \.isNewline) where line.hasPrefix("loc=") {
                let country = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if country.count == 2, country != "XX", country != "T1" { return (country.uppercased(), nil) }
            }
            return nil
        }
    }

    private static func jsonObject(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - 名字里的国家线索

    /// 国家/城市名（不区分大小写的子串）和中文名。两字母代码另按整词匹配（区分大小写，避免把英文单词当成代码）。
    static let nameKeywords: [(code: String, words: [String])] = [
        ("US", ["United States", "America", "Los Angeles", "New York", "San Jose", "Silicon Valley", "Seattle", "Chicago", "Dallas", "Miami", "Ashburn", "美国", "美國", "洛杉矶", "纽约", "硅谷", "矽谷", "西雅图", "西雅圖", "芝加哥"]),
        ("JP", ["Japan", "Tokyo", "Osaka", "日本", "东京", "東京", "大阪"]),
        ("SG", ["Singapore", "新加坡", "狮城", "獅城"]),
        ("TH", ["Thailand", "Bangkok", "泰国", "泰國", "曼谷"]),
        ("HK", ["Hong Kong", "HongKong", "香港"]),
        ("TW", ["Taiwan", "Taipei", "台湾", "台灣", "臺灣", "台北", "臺北"]),
        ("KR", ["Korea", "Seoul", "韩国", "韓國", "首尔", "首爾"]),
        ("GB", ["United Kingdom", "Britain", "England", "London", "英国", "英國", "伦敦", "倫敦"]),
        ("DE", ["Germany", "Frankfurt", "Berlin", "德国", "德國", "法兰克福", "法蘭克福"]),
        ("FR", ["France", "Paris", "法国", "法國", "巴黎"]),
        ("AU", ["Australia", "Sydney", "Melbourne", "澳洲", "澳大利亚", "悉尼", "雪梨"]),
        ("CA", ["Canada", "Toronto", "Vancouver", "Montreal", "加拿大", "多伦多", "温哥华"]),
        ("NL", ["Netherlands", "Amsterdam", "荷兰"]),
        ("IN", ["India", "Mumbai", "印度", "孟买"]),
        ("MY", ["Malaysia", "Kuala Lumpur", "马来西亚"]),
        ("VN", ["Vietnam", "Viet Nam", "Hanoi", "Ho Chi Minh", "越南"]),
        ("PH", ["Philippines", "Manila", "菲律宾"]),
        ("ID", ["Indonesia", "Jakarta", "印尼", "印度尼西亚"]),
        ("RU", ["Russia", "Moscow", "俄罗斯", "莫斯科"]),
        ("TR", ["Turkey", "Türkiye", "Istanbul", "土耳其"]),
        ("BR", ["Brazil", "Sao Paulo", "São Paulo", "巴西"]),
        ("IT", ["Italy", "Milan", "意大利"]),
        ("ES", ["Spain", "Madrid", "西班牙"]),
        ("CN", ["China", "Shanghai", "Beijing", "中国", "上海", "北京"]),
        ("MO", ["Macau", "Macao", "澳门", "澳門"]),
        ("AE", ["United Arab Emirates", "Dubai", "迪拜", "阿联酋"]),
    ]

    static let nameCodes: Set<String> = ["US", "USA", "JP", "SG", "TH", "HK", "TW", "KR", "UK", "GB", "DE", "FR", "AU", "CA", "NL", "MY", "VN", "PH", "ID", "RU", "TR", "BR", "IT", "ES", "MO", "AE", "LA", "NYC", "SJC", "LAX"]

    /// 中转节点名里的箭头（`入口 → 落地`）：真正的出口是最后一段。
    static let relayArrows = ["→", "➜", "➡️", "➡", "->", "=>", "»"]
    /// 名字里写了这些地区时，「中国 / China」只是前缀（「中国香港」「中国台湾」），不算中国大陆。
    static let specialRegionMarkers = ["香港", "台湾", "台灣", "臺灣", "澳门", "澳門", "Hong Kong", "HongKong", "Taiwan", "Macau", "Macao"]
    /// 节点名里常见的机场三字码 → 国家。
    static let airportCodes: [String: String] = [
        "HKG": "HK", "SIN": "SG", "NRT": "JP", "KIX": "JP", "ICN": "KR", "TPE": "TW",
        "BKK": "TH", "LHR": "GB", "FRA": "DE", "AMS": "NL", "SFO": "US", "SEA": "US",
    ]

    /// 推断节点名里的国家。中转线路（带箭头）先看最后一段（落地），看不出来再看整个名字。
    public static func inferCountry(from text: String) -> String? {
        if let arrow = relayArrows.compactMap({ text.range(of: $0, options: .backwards) }).max(by: { $0.lowerBound < $1.lowerBound }),
           let landing = inferCountryIgnoringRelay(from: String(text[arrow.upperBound...])) {
            return landing
        }
        return inferCountryIgnoringRelay(from: text)
    }

    /// 按出现位置最靠前的线索推断国家（位置统一用原文的 UTF-16 偏移）。
    static func inferCountryIgnoringRelay(from text: String) -> String? {
        let ns = text as NSString
        let mainlandIsPrefix = specialRegionMarkers.contains { ns.range(of: $0, options: .caseInsensitive).location != NSNotFound }
        var best: (position: Int, code: String)?
        func consider(_ position: Int, _ code: String) {
            if mainlandIsPrefix, code == "CN" { return }
            if best == nil || position < best!.position { best = (position, code) }
        }
        // 国旗：两个连续的 Regional Indicator Symbol。
        var offset = 0
        var previous: UInt32?
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if let first = previous, (0x1F1E6...0x1F1FF).contains(value) {
                let code = String(UnicodeScalar(first - 0x1F1E6 + 65)!) + String(UnicodeScalar(value - 0x1F1E6 + 65)!)
                consider(offset - 2, code == "UK" ? "GB" : code)
                previous = nil
            } else {
                previous = (0x1F1E6...0x1F1FF).contains(value) ? value : nil
            }
            offset += scalar.utf16.count
        }
        for (code, words) in nameKeywords {
            for word in words {
                let range = ns.range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
                if range.location != NSNotFound { consider(range.location, code) }
            }
        }
        // 两字母国家代码、常见三字母城市 / 机场代码：区分大小写；前面不能是字母或数字（「5TH」不算泰国），
        // 后面不能是字母（「HK01」这种带编号的照常识别）。
        let codes = nameCodes.union(airportCodes.keys)
        let pattern = "(?<![A-Za-z0-9])(" + codes.sorted { $0.count > $1.count }.joined(separator: "|") + ")(?![A-Za-z])"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let token = ns.substring(with: match.range(at: 1))
                if let country = airportCodes[token] {
                    consider(match.range.location, country)
                    continue
                }
                switch token {
                case "USA", "LA", "NYC", "SJC", "LAX": consider(match.range.location, "US")
                case "UK": consider(match.range.location, "GB")
                default: consider(match.range.location, token)
                }
            }
        }
        return best?.code
    }

    // MARK: - 经代理请求

    /// 用系统自带的 /usr/bin/curl 经代理请求：socks5h（DNS 也走代理）或 HTTP CONNECT。
    /// 代理地址和账号经标准输入的配置传给 curl（`-K -`），不出现在进程参数里。
    /// 不读 ~/.curlrc（`-q`）、不继承环境变量（http_proxy / NO_PROXY 等都不生效）、`noproxy` 置空，保证一定走这个代理。
    public static let curlFetch: Fetch = { url, proxy, password, timeout in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = curlArguments(timeout: timeout)
        process.environment = curlEnvironment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        guard writeConfig(Data(curlConfig(url: url, proxy: proxy, password: password).utf8), to: input.fileHandleForWriting) else {
            process.terminate()
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout + 2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// curl 的子进程环境：只有 PATH 和 LC_ALL，没有任何 *_proxy、CURL_HOME、HOME。
    static let curlEnvironment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]

    /// `-q` 必须是第一个参数才会跳过 ~/.curlrc。
    static func curlArguments(timeout: TimeInterval) -> [String] {
        ["-q", "-fsS", "--max-time", String(Int(max(1, timeout))), "-K", "-"]
    }

    /// 经标准输入交给 curl 的配置：每行一条，值都在引号里并转义，用户名 / 密码里的引号、换行注入不了新的配置行。
    static func curlConfig(url: String, proxy: ProxySettings, password: String?) -> String {
        let host = proxy.host.contains(":") ? "[\(proxy.host)]" : proxy.host
        let scheme = proxy.kind == .socks5 ? "socks5h" : "http"
        var config = "url = \"\(curlEscape(url))\"\nproxy = \"\(scheme)://\(host):\(proxy.port)\"\nnoproxy = \"\"\n"
        if let username = proxy.username, !username.isEmpty {
            config += "proxy-user = \"\(curlEscape(username)):\(curlEscape(password ?? ""))\"\n"
        }
        return config
    }

    /// 写配置并关掉 curl 的标准输入。curl 提前退出（管道没有读端）时，写入默认会触发 SIGPIPE 直接杀掉整个进程，
    /// `write(contentsOf:)` 的抛错接不住；先给这个管道设 F_SETNOSIGPIPE，写失败就只是返回 false。
    static func writeConfig(_ data: Data, to handle: FileHandle) -> Bool {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    static func curlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
