import XCTest
import SafarierCore
@testable import SafarierNetwork

/// 跟随代理：GeoIP 接口解析、节点名推断、探测顺序和回退、国家 → 语言 / 时区表、重启时带过去的结果。
/// 全部用假的 fetch，不访问网络。
final class ProxyGeoResolverTests: XCTestCase {
    private let proxy = ProxySettings(name: "edge", kind: .socks5, host: "127.0.0.1", port: 1080)

    /// 记录 fetch 收到的 URL，按 URL 返回预设正文（fetch 闭包是 @Sendable）。
    private final class FakeFetch: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [String] = []
        let bodies: [String: String]

        init(_ bodies: [String: String]) { self.bodies = bodies }

        var urls: [String] { lock.lock(); defer { lock.unlock() }; return _urls }

        var fetch: ProxyGeoResolver.Fetch {
            { [self] url, _, _, _ in
                lock.lock(); _urls.append(url); lock.unlock()
                return bodies[url]
            }
        }
    }

    private static let ipwhois = "https://ipwho.is/"
    private static let ipsb = "https://api.ip.sb/geoip"
    private static let trace = "https://www.cloudflare.com/cdn-cgi/trace"

    // MARK: - 接口解析

    func testParseIPWhoIs() throws {
        let body = #"{"ip":"203.0.113.7","success":true,"country_code":"JP","timezone":{"id":"Asia/Tokyo","utc":"+09:00"}}"#
        let parsed = try XCTUnwrap(ProxyGeoResolver.parse(body, kind: .ipwhois))
        XCTAssertEqual(parsed.country, "JP")
        XCTAssertEqual(parsed.timeZone, "Asia/Tokyo")
        XCTAssertNil(ProxyGeoResolver.parse(#"{"success":false,"message":"Reserved range"}"#, kind: .ipwhois))
        XCTAssertNil(ProxyGeoResolver.parse("<html>blocked</html>", kind: .ipwhois))
    }

    func testParseIPSB() throws {
        let body = #"{"ip":"198.51.100.2","country_code":"us","timezone":"America/New_York","organization":"Example"}"#
        let parsed = try XCTUnwrap(ProxyGeoResolver.parse(body, kind: .ipsb))
        XCTAssertEqual(parsed.country, "US")
        XCTAssertEqual(parsed.timeZone, "America/New_York")
        XCTAssertNil(ProxyGeoResolver.parse(#"{"country_code":"USA"}"#, kind: .ipsb))
    }

    func testParseCloudflareTrace() throws {
        let body = "fl=123f45\nh=www.cloudflare.com\nip=192.0.2.9\nloc=SG\ntls=TLSv1.3\n"
        let parsed = try XCTUnwrap(ProxyGeoResolver.parse(body, kind: .cloudflareTrace))
        XCTAssertEqual(parsed.country, "SG")
        XCTAssertNil(parsed.timeZone)
        XCTAssertNil(ProxyGeoResolver.parse("loc=XX\n", kind: .cloudflareTrace), "XX 是未知")
        XCTAssertNil(ProxyGeoResolver.parse("loc=T1\n", kind: .cloudflareTrace), "T1 是 Tor")
        XCTAssertNil(ProxyGeoResolver.parse("ip=192.0.2.9\n", kind: .cloudflareTrace))
    }

    // MARK: - 探测顺序与回退

    func testLookupSuccessStopsAtFirstEndpoint() throws {
        let fake = FakeFetch([Self.ipwhois: #"{"success":true,"country_code":"TH","timezone":{"id":"Asia/Bangkok"}}"#])
        let result = try XCTUnwrap(ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: "🇯🇵 Tokyo", fetch: fake.fetch))
        XCTAssertEqual(result.countryCode, "TH")
        XCTAssertEqual(result.languages, ["th-TH", "th"])
        XCTAssertEqual(result.timeZoneIdentifier, "Asia/Bangkok")
        XCTAssertEqual(result.source, .lookup(Self.ipwhois))
        XCTAssertEqual(fake.urls, [Self.ipwhois], "出口 IP 查到了就不看节点名，也不请求后面的接口")
    }

    func testFallsBackToNextEndpointAndPrefersLookupTimeZone() throws {
        let fake = FakeFetch([Self.ipsb: #"{"country_code":"US","timezone":"America/New_York"}"#])
        let result = try XCTUnwrap(ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: nil, fetch: fake.fetch))
        XCTAssertEqual(result.countryCode, "US")
        XCTAssertEqual(result.languages, ["en-US", "en"])
        XCTAssertEqual(result.timeZoneIdentifier, "America/New_York", "接口给了合法时区就用接口的，不用表里的默认")
        XCTAssertEqual(result.source, .lookup(Self.ipsb))
        XCTAssertEqual(fake.urls, [Self.ipwhois, Self.ipsb])
    }

    func testTraceOnlyGivesCountrySoTimeZoneComesFromTable() throws {
        let fake = FakeFetch([Self.trace: "loc=GB\n"])
        let result = try XCTUnwrap(ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: nil, fetch: fake.fetch))
        XCTAssertEqual(result.countryCode, "GB")
        XCTAssertEqual(result.languages, ["en-GB", "en"])
        XCTAssertEqual(result.timeZoneIdentifier, "Europe/London")
        XCTAssertEqual(fake.urls, ProxyGeoResolver.endpoints.map(\.url))
    }

    func testInvalidLookupTimeZoneFallsBackToTable() throws {
        let fake = FakeFetch([Self.ipwhois: #"{"success":true,"country_code":"JP","timezone":{"id":"Mars/Olympus"}}"#])
        let result = try XCTUnwrap(ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: nil, fetch: fake.fetch))
        XCTAssertEqual(result.timeZoneIdentifier, "Asia/Tokyo")
    }

    func testAllLookupsFailFallsBackToNodeName() throws {
        let fake = FakeFetch([Self.ipwhois: "garbage", Self.trace: "loc=XX\n"])
        let result = try XCTUnwrap(ProxyGeoResolver.resolve(proxy: proxy, password: nil, nodeHint: "🇯🇵 东京 IEPL 01", fetch: fake.fetch))
        XCTAssertEqual(result.countryCode, "JP")
        XCTAssertEqual(result.languages, ["ja-JP", "ja"])
        XCTAssertEqual(result.timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(result.source, .nameHint)
        XCTAssertEqual(fake.urls.count, ProxyGeoResolver.endpoints.count)
    }

    func testFallsBackToProxyNameWhenNodeHintHasNoClue() throws {
        let named = ProxySettings(name: "Singapore residential", kind: .httpConnect, host: "127.0.0.1", port: 8080)
        let fake = FakeFetch([:])
        let result = try XCTUnwrap(ProxyGeoResolver.resolve(proxy: named, password: nil, nodeHint: "node-07", fetch: fake.fetch))
        XCTAssertEqual(result.countryCode, "SG")
        XCTAssertEqual(result.source, .nameHint)
    }

    func testNoProxyNeverLooksUp() throws {
        let fake = FakeFetch([Self.ipwhois: #"{"success":true,"country_code":"DE"}"#])
        let result = try XCTUnwrap(ProxyGeoResolver.resolve(proxy: nil, password: nil, nodeHint: "🇰🇷 Seoul", fetch: fake.fetch))
        XCTAssertEqual(result.countryCode, "KR")
        XCTAssertTrue(fake.urls.isEmpty, "没有代理就不探测，避免用直连暴露真实 IP")
        XCTAssertNil(ProxyGeoResolver.resolve(proxy: nil, password: nil, nodeHint: nil, fetch: fake.fetch))
        XCTAssertNil(ProxyGeoResolver.resolve(proxy: nil, password: nil, nodeHint: "node-07", fetch: fake.fetch))
        XCTAssertTrue(fake.urls.isEmpty)
    }

    /// 真的跑一次 curl：代理端口没人监听，应当很快返回 nil，不挂住。
    func testCurlFetchToClosedProxyReturnsNil() {
        let closed = ProxySettings(name: "closed", kind: .socks5, host: "127.0.0.1", port: 9)
        let started = Date()
        XCTAssertNil(ProxyGeoResolver.curlFetch("https://ipwho.is/", closed, nil, 2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCurlEscape() {
        XCTAssertEqual(ProxyGeoResolver.curlEscape(#"a"b\c"#), #"a\"b\\c"#)
        XCTAssertEqual(ProxyGeoResolver.curlEscape("plain"), "plain")
        XCTAssertEqual(ProxyGeoResolver.curlEscape("a\nb\rc"), #"a\nb\rc"#, "换行和回车转义成 \\n、\\r")
        XCTAssertFalse(ProxyGeoResolver.curlEscape("x\"\nproxy = \"http://evil.invalid\"\r\n").contains(where: \.isNewline))
    }

    // MARK: - curl 的配置、参数和环境

    /// 用户名 / 密码里的引号和换行注入不了新的配置行：配置固定是 url、proxy、noproxy、proxy-user 四行。
    func testCurlConfigCannotBeInjected() {
        let proxy = ProxySettings(name: "p", kind: .socks5, host: "2001:db8::1", port: 1080, username: "al\"ice\nurl = \"http://evil.invalid/\"")
        let config = ProxyGeoResolver.curlConfig(url: "https://ipwho.is/", proxy: proxy, password: "pw\r\nproxy = \"http://evil.invalid:1\"")
        let lines = config.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 5, config)
        XCTAssertEqual(lines[0], #"url = "https://ipwho.is/""#)
        XCTAssertEqual(lines[1], #"proxy = "socks5h://[2001:db8::1]:1080""#, "IPv6 加方括号，socks5h 让 DNS 也走代理")
        XCTAssertEqual(lines[2], #"noproxy = """#, "不让任何主机绕过代理")
        XCTAssertEqual(lines[3], #"proxy-user = "al\"ice\nurl = \"http://evil.invalid/\":pw\r\nproxy = \"http://evil.invalid:1\"""#)
        XCTAssertEqual(lines[4], "")

        let http = ProxySettings(name: "h", kind: .httpConnect, host: "127.0.0.1", port: 8080)
        XCTAssertEqual(ProxyGeoResolver.curlConfig(url: "https://api.ip.sb/geoip", proxy: http, password: "ignored"),
                       "url = \"https://api.ip.sb/geoip\"\nproxy = \"http://127.0.0.1:8080\"\nnoproxy = \"\"\n", "没有用户名时不写 proxy-user")
    }

    func testCurlArgumentsAndEnvironmentAreIsolated() {
        let arguments = ProxyGeoResolver.curlArguments(timeout: 4)
        XCTAssertEqual(arguments.first, "-q", "-q 必须是第一个参数才会跳过 ~/.curlrc")
        XCTAssertEqual(arguments, ["-q", "-fsS", "--max-time", "4", "-K", "-"])
        XCTAssertEqual(ProxyGeoResolver.curlArguments(timeout: 0.2)[3], "1", "超时至少 1 秒")
        XCTAssertFalse(arguments.contains { $0.contains("proxy") || $0.contains("@") }, "代理和账号不出现在进程参数里")

        let environment = ProxyGeoResolver.curlEnvironment
        XCTAssertEqual(Set(environment.keys), ["PATH", "LC_ALL"])
        XCTAssertFalse(environment.keys.contains { $0.lowercased().contains("proxy") || $0 == "HOME" || $0 == "CURL_HOME" })
    }

    /// curl 提前退出（管道没有读端）时写配置不能触发 SIGPIPE 把整个进程杀掉（没有 F_SETNOSIGPIPE 时这个测试进程会直接退出）。
    func testWritingConfigToClosedPipeDoesNotKillProcess() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        XCTAssertFalse(ProxyGeoResolver.writeConfig(Data(repeating: 0x41, count: 4096), to: pipe.fileHandleForWriting))

        let open = Pipe()
        XCTAssertTrue(ProxyGeoResolver.writeConfig(Data("url = \"x\"\n".utf8), to: open.fileHandleForWriting))
        XCTAssertEqual(open.fileHandleForReading.readDataToEndOfFile(), Data("url = \"x\"\n".utf8), "写完会关掉写端（curl 读到 EOF）")
    }

    /// 端到端：真的跑 /usr/bin/curl 经本机一次性 HTTP 代理请求。带引号、反斜杠、换行的密码原样送达（注入的 url 不生效），
    /// 父进程设了 NO_PROXY=* / http_proxy 也照样走这个代理（子进程不继承环境变量，noproxy 为空）。
    func testCurlFetchGoesThroughProxyWithLiteralCredentials() throws {
        let server = try OneShotHTTPProxy()
        defer { server.stop() }
        let saved = ["NO_PROXY", "no_proxy", "http_proxy", "ALL_PROXY"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("NO_PROXY", "*", 1)
        setenv("no_proxy", "*", 1)
        setenv("http_proxy", "http://127.0.0.1:9", 1)
        setenv("ALL_PROXY", "socks5h://127.0.0.1:9", 1)
        defer {
            for (key, value) in saved {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let password = "pa\"ss\\\nurl = \"http://evil.invalid/\"\r!"
        let proxy = ProxySettings(name: "local", kind: .httpConnect, host: "127.0.0.1", port: Int(server.port), username: "alice")
        let body = ProxyGeoResolver.curlFetch("http://example.invalid/geo", proxy, password, 5)
        XCTAssertEqual(body, "ok")

        let requests = server.requests
        XCTAssertEqual(requests.count, 1, "只发了一个请求（注入的 url 没生效）")
        let lines = requests.first?.components(separatedBy: "\r\n") ?? []
        XCTAssertEqual(lines.first, "GET http://example.invalid/geo HTTP/1.1")
        let expected = "Proxy-Authorization: Basic " + Data("alice:\(password)".utf8).base64EncodedString()
        XCTAssertTrue(lines.contains(expected), "账号要原样送达：\(lines)")
    }

    // MARK: - 节点名推断

    func testInferCountryFromFlags() {
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "🇺🇸 美西 01"), "US")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "IPLC 🇭🇰 02"), "HK")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "🇬🇧 London"), "GB")
    }

    func testInferCountryFromNames() {
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "日本 东京 BGP"), "JP")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "香港-HKT-03"), "HK")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "泰国曼谷 AIS"), "TH")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "los angeles cn2 gia"), "US", "地名不区分大小写")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "São Paulo 1"), "BR")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "台北 HiNet"), "TW")
    }

    func testInferCountryFromCodes() {
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "SG-01"), "SG")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "node_JP_2"), "JP")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "UK 03"), "GB")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "USA premium"), "US")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "LAX-2"), "US")
    }

    func testInferCountryAvoidsFalsePositives() {
        XCTAssertNil(ProxyGeoResolver.inferCountry(from: "node-07"))
        XCTAssertNil(ProxyGeoResolver.inferCountry(from: "us-east plus"), "两字母代码区分大小写")
        XCTAssertNil(ProxyGeoResolver.inferCountry(from: "PLUS BONUS"), "代码前后不能是字母")
        XCTAssertNil(ProxyGeoResolver.inferCountry(from: "UUID-ABCDEF"))
        XCTAssertNil(ProxyGeoResolver.inferCountry(from: ""))
    }

    func testInferCountryPrefersEarliestClue() {
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "日本 中转 美国"), "JP", "没有箭头时取最靠前的线索")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "🇸🇬 via Hong Kong"), "SG")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "HK 转 SG"), "HK")
    }

    // MARK: - Round 3：中转、港台澳、繁体、机场代码、代码边界

    /// 中转线路（入口 → 落地）按最后一段判断；最后一段看不出来再看整个名字。
    func testRelayArrowsUseLandingSegment() {
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "🇭🇰 香港 → 🇯🇵 日本 IEPL"), "JP")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "SG -> US 01"), "US")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "上海 => 香港"), "HK")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "Tokyo » 🇺🇸 LA"), "US")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "HK ➡️ JP"), "JP")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "广州 ➜ 新加坡"), "SG")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "日本 → 美国 → 德国"), "DE", "多段取最后一段")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "Tokyo → node-07"), "JP", "落地段看不出来时看整个名字")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "Tokyo →"), "JP")
    }

    /// 「中国香港」「中国台湾」「中国澳门」不是中国大陆。
    func testChinaPrefixBeforeSpecialRegions() {
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "中国香港 01"), "HK")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "中国台湾 01"), "TW")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "中国台灣 HiNet"), "TW")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "中国澳门"), "MO")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "China Hong Kong 02"), "HK")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "🇨🇳 中国 → 🇭🇰 香港"), "HK")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "中国 上海 01"), "CN", "真的是大陆时照常")
    }

    func testTraditionalChineseKeywords() {
        let cases: [(String, String)] = [
            ("美國 洛杉磯", "US"), ("台灣 01", "TW"), ("倫敦", "GB"), ("法蘭克福 Hetzner", "DE"),
            ("矽谷", "US"), ("西雅圖", "US"), ("獅城", "SG"), ("雪梨", "AU"),
        ]
        for (text, code) in cases { XCTAssertEqual(ProxyGeoResolver.inferCountry(from: text), code, text) }
    }

    func testAirportCodes() {
        let cases: [(String, String)] = [
            ("HKG-01", "HK"), ("SIN 02", "SG"), ("NRT", "JP"), ("KIX-3", "JP"), ("ICN", "KR"), ("TPE 1", "TW"),
            ("BKK", "TH"), ("LHR", "GB"), ("FRA-x", "DE"), ("AMS", "NL"), ("SFO", "US"), ("SEA-01", "US"),
        ]
        for (text, code) in cases { XCTAssertEqual(ProxyGeoResolver.inferCountry(from: text), code, text) }
    }

    /// 代码前面不能是字母或数字（「5TH」不是泰国），后面可以跟数字（「HK01」照常识别）。
    func testCodeBoundaries() {
        XCTAssertNil(ProxyGeoResolver.inferCountry(from: "5TH Avenue"))
        XCTAssertNil(ProxyGeoResolver.inferCountry(from: "x5HK"))
        XCTAssertNil(ProxyGeoResolver.inferCountry(from: "THX"))
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "HK01"), "HK")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "JP2"), "JP")
        XCTAssertEqual(ProxyGeoResolver.inferCountry(from: "[SG]02"), "SG")
    }

    // MARK: - 国家表

    func testCountryTableCoversCommonCountriesWithValidZones() {
        XCTAssertGreaterThanOrEqual(CountryLocaleTable.entries.count, 60)
        let tagPattern = "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"
        for (code, entry) in CountryLocaleTable.entries {
            XCTAssertEqual(code.count, 2, code)
            XCTAssertEqual(code, code.uppercased(), code)
            XCTAssertNotNil(TimeZone(identifier: entry.timeZoneIdentifier), "\(code): \(entry.timeZoneIdentifier)")
            XCTAssertFalse(entry.languages.isEmpty, code)
            for tag in entry.languages {
                XCTAssertNotNil(tag.range(of: tagPattern, options: .regularExpression), "\(code): \(tag) 过不了 Profile 的语言标签校验")
            }
        }
    }

    func testCountryTableKeyEntries() throws {
        let us = try XCTUnwrap(CountryLocaleTable.locale(for: "US"))
        XCTAssertEqual(us.languages, ["en-US", "en"])
        XCTAssertEqual(us.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(CountryLocaleTable.locale(for: "jp")?.languages, ["ja-JP", "ja"], "代码不区分大小写")
        XCTAssertEqual(CountryLocaleTable.locale(for: "TH")?.timeZoneIdentifier, "Asia/Bangkok")
        XCTAssertEqual(CountryLocaleTable.locale(for: "HK")?.languages.first, "zh-HK")
        XCTAssertEqual(CountryLocaleTable.locale(for: "TW")?.languages, ["zh-TW", "zh-Hant"])
        XCTAssertEqual(CountryLocaleTable.locale(for: "TW")?.name, "Taiwan")
        XCTAssertEqual(CountryLocaleTable.locale(for: "CN")?.timeZoneIdentifier, "Asia/Shanghai")
    }

    func testUnlistedCountryUsesLikelySubtagsWithLookupTimeZone() throws {
        XCTAssertNil(CountryLocaleTable.entries["EC"], "测试前提：厄瓜多尔不在表里")
        let ecuador = try XCTUnwrap(CountryLocaleTable.locale(for: "EC", fallbackTimeZone: "America/Guayaquil"))
        XCTAssertEqual(ecuador.languages, ["es-EC", "es"])
        XCTAssertEqual(ecuador.timeZoneIdentifier, "America/Guayaquil")
        XCTAssertNil(CountryLocaleTable.locale(for: "EC"), "表里没有又没有时区时不猜")
        XCTAssertNil(CountryLocaleTable.locale(for: "EC", fallbackTimeZone: "Mars/Olympus"))
        XCTAssertNil(CountryLocaleTable.locale(for: "E1", fallbackTimeZone: "America/Guayaquil"))
        XCTAssertNil(CountryLocaleTable.locale(for: "ECU", fallbackTimeZone: "America/Guayaquil"))
    }

    // MARK: - 重启时带过去

    func testRelaunchEnvironmentRoundTrip() throws {
        for source in [ProxyGeoResult.Source.lookup(Self.ipsb), .nameHint] {
            let result = ProxyGeoResult(countryCode: "HK", languages: ["zh-HK", "zh-Hant", "en"], timeZoneIdentifier: "Asia/Hong_Kong", source: source)
            let environment = result.relaunchEnvironment
            XCTAssertEqual(environment[ProxyGeoResult.relaunchFlag], "1")
            XCTAssertEqual(ProxyGeoResult(relaunchedFrom: environment), result)
        }
    }

    func testRelaunchEnvironmentRejectsIncompleteValues() {
        let environment = ProxyGeoResult(countryCode: "JP", languages: ["ja-JP", "ja"], timeZoneIdentifier: "Asia/Tokyo", source: .nameHint)
            .relaunchEnvironment
        XCTAssertNil(ProxyGeoResult(relaunchedFrom: [:]))
        var noFlag = environment
        noFlag[ProxyGeoResult.relaunchFlag] = nil
        XCTAssertNil(ProxyGeoResult(relaunchedFrom: noFlag))
        var badZone = environment
        badZone["SAFARIER_GEO_TIMEZONE"] = "Mars/Olympus"
        XCTAssertNil(ProxyGeoResult(relaunchedFrom: badZone))
        var noLanguages = environment
        noLanguages["SAFARIER_GEO_LANGUAGES"] = ""
        XCTAssertNil(ProxyGeoResult(relaunchedFrom: noLanguages))
    }
}

/// 测试用的本机 HTTP 代理：监听 127.0.0.1 的随机端口，记下每个请求头，回 `200 ok`。
final class OneShotHTTPProxy: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var recorded: [String] = []

    var requests: [String] { lock.lock(); defer { lock.unlock() }; return recorded }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    private func serve() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !(String(data: data, encoding: .utf8) ?? "").contains("\r\n\r\n") {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            lock.lock()
            recorded.append(String(data: data, encoding: .utf8) ?? "")
            lock.unlock()
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
            _ = response.withCString { write(client, $0, strlen($0)) }
            close(client)
        }
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }
}
