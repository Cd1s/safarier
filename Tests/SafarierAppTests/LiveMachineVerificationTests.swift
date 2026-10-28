import XCTest
import AppKit
import WebKit
import SafarierCore
import SafarierWebKit
@testable import Safarier

/// 实体机常规检测：每次 `swift test` 都在这台机器的真实 WebKit 上跑一遍检测站常用的探测。
///
/// - 字体：在 WKWebView 的主线程和 Worker 里原样跑 fuck-claude.vercel.app 的 Canvas measureText 宽度探测
///   （27 款简繁中文字体、16 款国产厂商字体），用 Runner 同一套配置工厂；
/// - Canvas 噪声、时区、语言、屏幕：启动真实的 Runner 进程（`run --probe`，带 -AppleLanguages、TZ 和屏幕模拟），
///   读它在主线程和 Worker 里实际看到的值。语言和屏幕是进程级设置，只能这样端到端地测。
@MainActor
final class LiveMachineVerificationTests: XCTestCase {
    /// 检测站的简繁中文字体列表（FONTS_SC + FONTS_TC）。
    static let chineseFonts = [
        "Microsoft YaHei", "Microsoft YaHei UI", "SimSun", "NSimSun", "SimHei", "KaiTi", "FangSong", "DengXian", "PingFang SC",
        "Hiragino Sans GB", "STHeiti", "STSong", "Songti SC", "Source Han Sans CN", "Source Han Sans SC", "Noto Sans CJK SC",
        "Noto Serif CJK SC", "WenQuanYi Micro Hei", "WenQuanYi Zen Hei", "Microsoft JhengHei", "PMingLiU", "MingLiU", "DFKai-SB",
        "PingFang TC", "PingFang HK", "Source Han Sans TW", "Noto Sans CJK TC",
    ]
    /// 检测站的国产厂商 / 软件字体列表（FONTS_CN_VENDOR）。
    static let vendorFonts = [
        "MiSans", "MIUI", "HarmonyOS Sans SC", "HarmonyOS Sans", "HONOR Sans", "OPPO Sans", "vivo Sans", "Alibaba PuHuiTi",
        "Alibaba Sans", "DingTalk JinBuTi", "Douyin Sans", "HYQiHei", "FZShuSong-Z01S", "FZKai-Z03S", "FZHei-B01S", "FZFangSong-Z02S",
    ]
    static let standardFonts = ["Times", "Courier", "Helvetica"]

    /// 检测站的 isFontAvailable 原样照搬：72px，monospace / sans-serif / serif 三个基准，宽度差超过 0.5 就算装了。
    /// Worker 里用 OffscreenCanvas 跑同一个函数。
    static let fontProbeScript = """
    const detect = (makeContext, chinese, vendor, standard) => {
      const ctx = makeContext();
      if (!ctx) return { error: 'canvas unavailable' };
      const isFontAvailable = (font) => {
        const testString = '中文字体检测ABCabc012';
        const size = '72px';
        const bases = ['monospace', 'sans-serif', 'serif'];
        return bases.some((base) => {
          ctx.font = `${size} ${base}`;
          const baseWidth = ctx.measureText(testString).width;
          ctx.font = `${size} "${font}", ${base}`;
          const testWidth = ctx.measureText(testString).width;
          return Math.abs(testWidth - baseWidth) > 0.5;
        });
      };
      return { chinese: chinese.filter(isFontAvailable), vendor: vendor.filter(isFontAvailable), standard: standard.filter(isFontAvailable) };
    };
    const main = detect(() => document.createElement('canvas').getContext('2d'), chinese, vendor, standard);
    const source = 'const detect = ' + detect.toString() + '; postMessage(detect(() => new OffscreenCanvas(16, 16).getContext("2d"), '
      + JSON.stringify(chinese) + ', ' + JSON.stringify(vendor) + ', ' + JSON.stringify(standard) + '));';
    const worker = await new Promise((resolve) => {
      const w = new Worker(URL.createObjectURL(new Blob([source], { type: 'text/javascript' })));
      const timer = setTimeout(() => { w.terminate(); resolve({ error: 'timeout' }); }, 8000);
      w.onmessage = (event) => { clearTimeout(timer); w.terminate(); resolve(event.data); };
      w.onerror = (event) => { clearTimeout(timer); resolve({ error: String(event.message || 'worker error') }); };
    });
    return JSON.stringify({ main, worker });
    """

    private struct FontHits: Decodable, Equatable {
        var chinese: [String]?
        var vendor: [String]?
        var standard: [String]?
        var error: String?
    }

    private struct FontProbe: Decodable {
        let main: FontHits
        let worker: FontHits
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done = true }
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// 和 Runner 一样用配置工厂（公开适配器 + SPI 适配器）建环境的配置。
    private func makeOutput(_ profile: Profile) throws -> WebViewConfigurationFactory.Output {
        let privacy = CompositePrivacyAdapter([
            PublicAPIPrivacyAdapter(),
            SPIPrivacyAdapter(features: profile.spi, diagnostics: SPIDiagnostics()),
        ])
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), privacy: privacy)
        return try factory.make(profile: profile, proxy: nil, processLanguages: profile.languages)
    }

    /// 在屏幕外窗口里的真实 WKWebView 上跑字体探测（WKWebView 不在窗口里时计时器会被节流，Worker 结果拿不到）。
    private func probeFonts(_ configuration: WKWebViewConfiguration) throws -> FontProbe {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        window.contentView = webView
        window.orderBack(nil)
        defer { window.close() }
        let loader = Loader()
        webView.navigationDelegate = loader
        webView.loadHTMLString("<!doctype html><meta charset=utf-8><body>live</body>", baseURL: URL(string: "https://live.safarier.invalid/"))
        spin(until: { loader.done })
        XCTAssertTrue(loader.done, "页面没有载入")

        var result: Result<Any, Error>?
        let arguments: [String: Any] = ["chinese": Self.chineseFonts, "vendor": Self.vendorFonts, "standard": Self.standardFonts]
        webView.callAsyncJavaScript(Self.fontProbeScript, arguments: arguments, in: nil, in: .page) { result = $0 }
        spin(until: { result != nil })
        let json = try XCTUnwrap(try XCTUnwrap(result, "探测脚本超时").get() as? String)
        return try JSONDecoder().decode(FontProbe.self, from: Data(json.utf8))
    }

    // MARK: - 字体

    /// 英文环境（en-US, en + Asia/Singapore，默认 SPI）：检测站的中文字体和国产厂商字体主线程、Worker 都是 none detected，
    /// Times / Courier / Helvetica 照常可用。同一台机器上的简体中文环境能测出中文字体，证明探测本身是灵的。
    func testEnglishProfileHidesAllChineseAndVendorFontsInCanvasProbe() throws {
        let english = Profile(name: "live-en", mode: .ephemeral, languages: ["en-US", "en"], timeZoneIdentifier: "Asia/Singapore")
        let output = try makeOutput(english)
        XCTAssertEqual(output.report[.fontAllowlist].name, "active", output.report[.fontAllowlist].summary)

        let probe = try probeFonts(output.configuration)
        for (thread, hits) in [("main", probe.main), ("worker", probe.worker)] {
            XCTAssertNil(hits.error, "\(thread)：\(hits.error ?? "")")
            XCTAssertEqual(hits.chinese, [], "\(thread) 检出了中文字体")
            XCTAssertEqual(hits.vendor, [], "\(thread) 检出了国产厂商字体")
            XCTAssertEqual(hits.standard, Self.standardFonts, "\(thread) 的英文标准字体不全")
        }

        let chinese = Profile(name: "live-zh", mode: .ephemeral, languages: ["zh-CN"], timeZoneIdentifier: "Asia/Singapore")
        let control = try probeFonts(try makeOutput(chinese).configuration)
        XCTAssertFalse(control.main.chinese?.isEmpty ?? true, "简体中文环境应能测出系统中文字体：\(control.main)")
        XCTAssertFalse(control.worker.chinese?.isEmpty ?? true, "简体中文环境应能测出系统中文字体：\(control.worker)")
        print("[live] 中文环境检出：\(control.main.chinese ?? [])")
    }

    // MARK: - 真实 Runner 探针

    /// 编好的 Safarier 可执行文件（`swift test` 和测试包一起编在同一个目录里）。
    private func safarierExecutable() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Safarier")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("找不到 \(url.path)，先运行 swift build")
        }
        return url
    }

    /// 在临时元数据目录里建好环境，启动真实 Runner 的探针模式，返回它输出的 JSON。
    private func runProbe(_ profile: Profile, spi: SPIFeatures? = nil) throws -> [String: Any] {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("LiveMachineVerification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = SafarierWorkspace(root: home)
        try workspace.profiles.insert(profile)
        let spec = workspace.runnerSpec(for: profile, probe: true, spiOverride: spi)

        let process = Process()
        process.executableURL = try safarierExecutable()
        process.arguments = spec.arguments()
        var base = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("XCTest") }
        base["SAFARIER_HOME"] = home.path
        process.environment = spec.environment(inheriting: base)
        let stdout = Pipe()
        let stderrURL = home.appendingPathComponent("probe.stderr")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        process.standardOutput = stdout
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "探针退出码 \(process.terminationStatus)：\(stderr.suffix(2000))")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], "探针没有输出 JSON：\(stderr.suffix(2000))")
    }

    private func observed(_ document: [String: Any], _ thread: String) throws -> [String: Any] {
        let observed = try XCTUnwrap(document["observed"] as? [String: Any], "\(document["error"] ?? "没有 observed")")
        let value = try XCTUnwrap(observed[thread] as? [String: Any], thread)
        XCTAssertNil(value["error"], "\(thread)：\(value["error"] ?? "")")
        return value
    }

    private func capability(_ document: [String: Any], _ feature: PrivacyFeature) -> String {
        let capabilities = document["capabilities"] as? [String: Any]
        return (capabilities?[feature.rawValue] as? [String: Any])?["state"] as? String ?? "missing"
    }

    private func canvasHashes(_ document: [String: Any]) throws -> [String: String] {
        let fingerprint = try XCTUnwrap(try observed(document, "main")["fingerprint"] as? [String: Any])
        return try XCTUnwrap(fingerprint["canvas"] as? [String: String], "\(fingerprint)")
    }

    // MARK: - Canvas 噪声

    /// 开启 fingerprintingProtections（高级隐私保护）后，Canvas 读出的像素哈希和未开启时不同，说明苹果原生的 Canvas 噪声生效了；
    /// 同一页面内重复读取、重新画一张都一致（噪声按会话固定，不是每次读都变）。未开启时两次运行哈希完全相同，差异不是渲染抖动。
    func testCanvasFingerprintingProtectionAddsSessionNoise() throws {
        let profile = Profile(name: "live-canvas", mode: .ephemeral, languages: ["en-US", "en"], timeZoneIdentifier: "Asia/Singapore")
        let unprotectedFeatures = SPIFeatures.defaultFeatures.subtracting(.fingerprintingProtections)

        let plain = try runProbe(profile, spi: unprotectedFeatures)
        let plainAgain = try runProbe(profile, spi: unprotectedFeatures)
        let protected = try runProbe(profile, spi: .defaultFeatures)
        XCTAssertEqual(capability(plain, .advancedPrivacyProtections), "notRequested")
        XCTAssertEqual(capability(protected, .advancedPrivacyProtections), "active")

        let baseline = try canvasHashes(plain)
        let noisy = try canvasHashes(protected)
        print("[live] canvas 未开启：\(baseline)，开启：\(noisy)")
        XCTAssertEqual(baseline, try canvasHashes(plainAgain), "未开启高级隐私保护时 Canvas 输出应稳定")
        XCTAssertNotEqual(noisy["dataURL"], baseline["dataURL"], "开启后 toDataURL 应带原生噪声")
        XCTAssertNotEqual(noisy["imageData"], baseline["imageData"], "开启后 getImageData 应带原生噪声")
        XCTAssertEqual(noisy["dataURLRepeat"], noisy["dataURL"], "同一张画布重复读取应一致")
        XCTAssertEqual(noisy["dataURLFreshCanvas"], noisy["dataURL"], "同一页面重新画一张应一致")
    }

    // MARK: - 时区、语言、屏幕

    /// 真实 Runner（-AppleLanguages、TZ、引擎时区、屏幕模拟、机型像素比）：主线程和 Worker 的时区、UTC 偏移、语言都精确生效；
    /// Mac mini (M4) 的 devicePixelRatio 2、P3 色域生效。屏幕尺寸关闭高级隐私保护时是模拟显示器 1920×1080（可用 1920×1055）；
    /// 开启时和 Safari 一样报窗口尺寸（防止用屏幕尺寸做指纹）。
    func testRegionTimeZoneAndScreenGeometryEndToEnd() throws {
        let model = try XCTUnwrap(MacDeviceModel.preset("mac-mini-m4"))
        let profile = Profile(name: "live-geo", mode: .ephemeral, languages: ["en-US", "en"], timeZoneIdentifier: "Asia/Singapore", deviceModel: model.id)

        let protected = try runProbe(profile)
        let unprotected = try runProbe(profile, spi: SPIFeatures.defaultFeatures.subtracting(.fingerprintingProtections))
        for feature in [PrivacyFeature.timeZone, .languages, .displayCapabilities, .deviceModel, .fontAllowlist] {
            XCTAssertEqual(capability(protected, feature), "active", feature.rawValue)
        }

        for (label, document) in [("afp", protected), ("no-afp", unprotected)] {
            for thread in ["main", "worker"] {
                let values = try observed(document, thread)
                let context = "\(label) \(thread)"
                XCTAssertEqual(values["timeZone"] as? String, "Asia/Singapore", context)
                XCTAssertEqual(values["timezoneOffsetMinutes"] as? Int, -480, context)
                XCTAssertEqual(values["januaryOffsetMinutes"] as? Int, -480, context)
                XCTAssertEqual(values["julyOffsetMinutes"] as? Int, -480, context)
                XCTAssertEqual(values["locale"] as? String, "en-US", context)
                XCTAssertEqual(values["language"] as? String, "en-US", context)
                // WebKit 和 Safari 一样只公开首选语言。
                XCTAssertEqual(values["languages"] as? [String], ["en-US"], context)
            }
            let main = try observed(document, "main")
            let display = try XCTUnwrap(main["display"] as? [String: Any], label)
            XCTAssertEqual(main["devicePixelRatio"] as? Int, model.scale, label)
            XCTAssertEqual(display["colorGamutP3"] as? Bool, true, label)
            XCTAssertEqual(display["dynamicRangeHigh"] as? Bool, false, "\(label)：Mac mini (M4) 的 4K 显示器是 SDR")
        }

        let screen = try observed(unprotected, "main")
        XCTAssertEqual(screen["screen"] as? [Int], [model.screenWidth, model.screenHeight, model.scale])
        XCTAssertEqual(screen["availScreen"] as? [Int], [model.availWidth, model.availHeight])

        let window = try XCTUnwrap((protected["geometry"] as? [String: Any])?["probeWindowSize"] as? [Int])
        let afpScreen = try observed(protected, "main")
        XCTAssertEqual(afpScreen["screen"] as? [Int], window + [model.scale], "高级隐私保护下 screen 报窗口尺寸")
        XCTAssertEqual(afpScreen["availScreen"] as? [Int], window)
    }
}
