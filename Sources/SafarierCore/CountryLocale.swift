import Foundation

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

    /// 按 IANA 时区的国家选择语言，不按 UTC 偏移猜测（纽约和利马可以有相同偏移）。
    /// GMT / UTC 等没有所属国家的时区返回 nil。
    public static func locale(forTimeZone identifier: String) -> CountryLocale? {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        if let country = timeZoneCountries[identifier] {
            return locale(for: country, fallbackTimeZone: identifier)
        }
        // zone.tab 只列正式标识。兼容 US/Pacific、Asia/Calcutta、Japan 等别名，
        // 比较完整时区数据而不是当前偏移；多个国家共用数据时不猜测。
        guard identifier.contains("/") || ["Japan", "PRC", "ROC", "ROK", "GB", "NZ"].contains(identifier) else { return nil }
        let data = (zone as NSTimeZone).data
        let countries = Set(timeZoneCountries.compactMap { name, country in
            TimeZone(identifier: name).flatMap { ($0 as NSTimeZone).data == data ? country : nil }
        })
        guard countries.count == 1, let country = countries.first else { return nil }
        return locale(for: country, fallbackTimeZone: identifier)
    }

    private static let timeZoneCountries: [String: String] = {
        var countries = Dictionary(uniqueKeysWithValues: entries.map { ($0.value.timeZoneIdentifier, $0.key) })
        // macOS 自带的 IANA 国家表覆盖多时区国家，随系统 tzdata 更新。
        if let table = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) {
            for line in table.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
                let fields = line.split(separator: "\t")
                guard fields.count >= 3, fields[0].count == 2 else { continue }
                countries[String(fields[2])] = String(fields[0])
            }
        }
        return countries
    }()
}
