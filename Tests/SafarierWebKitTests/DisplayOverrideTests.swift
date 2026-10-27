import XCTest
import AppKit
import AVFoundation
import WebKit
import SafarierCore
@testable import SafarierWebKit

/// 屏幕能力模拟：替换的是进程级的 NSScreen / AVPlayer 查询，每个用例结束都要撤销。
@MainActor
final class DisplayOverrideTests: XCTestCase {
    private var screen: NSScreen!
    private var displayID: NSNumber!
    private var originalP3 = false
    private var originalRange = ""

    override func setUp() async throws {
        screen = try XCTUnwrap(NSScreen.main)
        displayID = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        DeviceSimulation.removeDisplayOverride()
        originalP3 = screen.canRepresent(.p3)
        originalRange = videoRange()
    }

    override func tearDown() async throws {
        DeviceSimulation.removeDisplayOverride()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    }

    private func videoRange() -> String {
        (AVPlayer.self as AnyObject).perform(NSSelectorFromString(SFRSymbolDecoder.decode([0x2A, 0x28, 0x3F, 0x3C, 0x3F, 0x28, 0x28, 0x3F, 0x3E, 0x0C, 0x33, 0x3E, 0x3F, 0x35, 0x08, 0x3B, 0x34, 0x3D, 0x3F, 0x1C, 0x35, 0x28, 0x1E, 0x33, 0x29, 0x2A, 0x36, 0x3B, 0x23, 0x29, 0x60])), with: [displayID!])?
            .takeUnretainedValue() as? String ?? ""
    }

    func testMacBookProGetsP3AndHDRThenRestores() {
        let state = DeviceSimulation.installDisplayOverride(for: .macBookPro16M3Max, diagnostics: SPIDiagnostics())
        XCTAssertEqual(state.name, "active", state.summary)
        XCTAssertTrue(screen.canRepresent(.p3))
        XCTAssertTrue(screen.canRepresent(.sRGB))
        // 直接是机型的余量，不混入宿主机屏幕的值（宿主机是 XDR 屏时也不会报得更高）。
        XCTAssertEqual(screen.maximumPotentialExtendedDynamicRangeColorComponentValue, 16)
        XCTAssertEqual(screen.maximumExtendedDynamicRangeColorComponentValue, 2)
        XCTAssertEqual(videoRange(), SFRSymbolDecoder.decode([0x1B, 0x0C, 0x0C, 0x33, 0x3E, 0x3F, 0x35, 0x08, 0x3B, 0x34, 0x3D, 0x3F, 0x12, 0x1E, 0x08, 0x6B, 0x6A]))

        DeviceSimulation.removeDisplayOverride()
        XCTAssertEqual(screen.canRepresent(.p3), originalP3)
        XCTAssertEqual(videoRange(), originalRange)
    }

    /// 非 HDR 机型报 SDR：不管宿主机是不是 XDR 屏，EDR 余量都是 1、视频范围都是 SDR。
    func testMacBookAirGetsP3AndSDREvenOnHDRHost() {
        XCTAssertEqual(DeviceSimulation.installDisplayOverride(for: .macBookAir13M2, diagnostics: SPIDiagnostics()).name, "active")
        XCTAssertTrue(screen.canRepresent(.p3))
        XCTAssertEqual(screen.maximumPotentialExtendedDynamicRangeColorComponentValue, 1)
        XCTAssertEqual(screen.maximumExtendedDynamicRangeColorComponentValue, 1)
        XCTAssertEqual(videoRange(), SFRSymbolDecoder.decode([0x1B, 0x0C, 0x0C, 0x33, 0x3E, 0x3F, 0x35, 0x08, 0x3B, 0x34, 0x3D, 0x3F, 0x09, 0x1E, 0x08]))
    }

    /// Mac Studio 按接 Studio Display（5K Retina、P3、SDR）算。
    func testMacStudioWithStudioDisplayGetsP3AndSDR() {
        XCTAssertEqual(DeviceSimulation.installDisplayOverride(for: .macStudioM2Ultra, diagnostics: SPIDiagnostics()).name, "active")
        XCTAssertTrue(screen.canRepresent(.p3))
        XCTAssertEqual(videoRange(), SFRSymbolDecoder.decode([0x1B, 0x0C, 0x0C, 0x33, 0x3E, 0x3F, 0x35, 0x08, 0x3B, 0x34, 0x3D, 0x3F, 0x09, 0x1E, 0x08]))
    }

    /// 接 1080p 普通显示器的 Mac mini：不报 P3，sRGB 照常。
    func testSRGBModelHidesP3() throws {
        let mini = try XCTUnwrap(MacDeviceModel.preset("mac-mini-m2"))
        XCTAssertEqual(DeviceSimulation.installDisplayOverride(for: mini, diagnostics: SPIDiagnostics()).name, "active")
        XCTAssertFalse(screen.canRepresent(.p3))
        XCTAssertTrue(screen.canRepresent(.sRGB))
        XCTAssertEqual(videoRange(), SFRSymbolDecoder.decode([0x1B, 0x0C, 0x0C, 0x33, 0x3E, 0x3F, 0x35, 0x08, 0x3B, 0x34, 0x3D, 0x3F, 0x09, 0x1E, 0x08]))
    }

    func testReinstallingReplacesPreviousOverride() {
        _ = DeviceSimulation.installDisplayOverride(for: .macBookPro16M3Max, diagnostics: SPIDiagnostics())
        _ = DeviceSimulation.installDisplayOverride(for: .macBookAir13M2, diagnostics: SPIDiagnostics())
        XCTAssertTrue(screen.canRepresent(.p3))
        XCTAssertEqual(videoRange(), SFRSymbolDecoder.decode([0x1B, 0x0C, 0x0C, 0x33, 0x3E, 0x3F, 0x35, 0x08, 0x3B, 0x34, 0x3D, 0x3F, 0x09, 0x1E, 0x08]), "换成 MacBook Air 后不应再报 HDR")
    }

    /// 端到端：WebKit 重新收集屏幕属性后，网页的媒体查询原生给出 P3 / HDR，不需要任何页面脚本。
    func testPageMediaQueriesFollowOverride() throws {
        _ = NSApplication.shared
        _ = DeviceSimulation.installDisplayOverride(for: .macBookPro16M3Max, diagnostics: SPIDiagnostics())
        // WebKit 监听这个通知重新收集 ScreenProperties（同一进程里之前的用例可能已经缓存过）。
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: window.contentView!.bounds, configuration: WKWebViewConfiguration())
        window.contentView = webView
        window.orderFront(nil)
        defer { window.close() }
        webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://example.invalid/"))
        let done = expectation(description: "evaluated")
        var result: [Bool] = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            webView.evaluateJavaScript("[matchMedia('(color-gamut: p3)').matches, matchMedia('(dynamic-range: high)').matches]") { value, _ in
                result = (value as? [Bool]) ?? []
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 15)
        XCTAssertEqual(result, [true, true])
    }
}
