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
    private var hostFrame = NSRect.zero
    private var hostVisibleFrame = NSRect.zero

    override func setUp() async throws {
        screen = try XCTUnwrap(NSScreen.main)
        displayID = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        DeviceSimulation.removeDisplayOverride()
        originalP3 = screen.canRepresent(.p3)
        originalRange = videoRange()
        hostFrame = screen.frame
        hostVisibleFrame = screen.visibleFrame
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

    // MARK: - 显示器几何（Issue #1）

    /// 安装后 NSScreen 的 frame / visibleFrame 就是目标显示器（可用高度扣掉菜单栏），撤销后回到宿主机的值。
    func testScreenGeometryFollowsModelThenRestores() throws {
        let studio = try XCTUnwrap(MacDeviceModel.preset("mac-studio-m4-max"))
        XCTAssertEqual(DeviceSimulation.installDisplayOverride(for: studio, diagnostics: SPIDiagnostics()).name, "active")
        XCTAssertEqual(screen.frame, NSRect(x: 0, y: 0, width: 2560, height: 1440))
        XCTAssertEqual(screen.visibleFrame, NSRect(x: 0, y: 0, width: 2560, height: 1415))
        XCTAssertEqual(NSScreen.main?.frame.size, NSSize(width: 2560, height: 1440))

        DeviceSimulation.removeDisplayOverride()
        XCTAssertEqual(screen.frame, hostFrame)
        XCTAssertEqual(screen.visibleFrame, hostVisibleFrame)
    }

    func testLaptopScreenGeometryUsesBuiltInDisplayAndNotch() {
        _ = DeviceSimulation.installDisplayOverride(for: .macBookPro16M3Max, diagnostics: SPIDiagnostics())
        XCTAssertEqual(screen.frame, NSRect(x: 0, y: 0, width: 1728, height: 1117))
        XCTAssertEqual(screen.visibleFrame, NSRect(x: 0, y: 0, width: 1728, height: 1080), "刘海屏菜单栏 37")
        // 重新安装换成新机型的几何。
        _ = DeviceSimulation.installDisplayOverride(for: .macBookAir13M2, diagnostics: SPIDiagnostics())
        XCTAssertEqual(screen.frame, NSRect(x: 0, y: 0, width: 1470, height: 956))
        XCTAssertEqual(screen.visibleFrame, NSRect(x: 0, y: 0, width: 1470, height: 919))
    }

    /// 没给显示器几何（宽或高为 0）时不替换 frame / visibleFrame，只替换色域和 HDR。
    func testNoGeometryLeavesFrameAlone() throws {
        let result = SPIRuntimeBridge.installDisplayOverride(p3: true, hdr: false, maxHeadroom: 1, currentHeadroom: 1,
                                                            screenWidth: 0, screenHeight: 900, availHeight: 875)
        XCTAssertNoThrow(try result.get())
        XCTAssertTrue(screen.canRepresent(.p3))
        XCTAssertEqual(screen.frame, hostFrame)
        XCTAssertEqual(screen.visibleFrame, hostVisibleFrame)
    }

    /// 窗口布局不受模拟影响：AppKit 自己居中、约束窗口时用宿主机的真实屏幕，hostVisibleFrame 也一直是真实值。
    /// 否则在更小的宿主机屏幕上，窗口会按模拟显示器的尺寸摆到屏幕外。
    func testWindowLayoutKeepsHostScreen() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.center()
        let centered = window.frame
        let offscreen = NSRect(x: hostVisibleFrame.minX + 100, y: hostVisibleFrame.maxY + 400, width: 800, height: 500)
        let constrained = window.constrainFrameRect(offscreen, to: screen)
        XCTAssertEqual(DeviceSimulation.hostVisibleFrame, hostVisibleFrame)

        let studio = try XCTUnwrap(MacDeviceModel.preset("mac-studio-m4-max"))
        _ = DeviceSimulation.installDisplayOverride(for: studio, diagnostics: SPIDiagnostics())
        XCTAssertEqual(screen.frame.size, NSSize(width: 2560, height: 1440), "测试前提：覆盖已生效")
        window.setFrame(NSRect(origin: .zero, size: centered.size), display: false)
        window.center()
        XCTAssertEqual(window.frame, centered, "AppKit 居中按宿主机屏幕，不按 2560×1440")
        XCTAssertEqual(window.constrainFrameRect(offscreen, to: screen), constrained, "AppKit 约束窗口按宿主机可用区域")
        XCTAssertEqual(DeviceSimulation.hostVisibleFrame, hostVisibleFrame, "模拟期间 hostVisibleFrame 仍是宿主机的值")
    }

    /// 端到端：关闭高级隐私保护时，网页的 screen / avail 就是目标显示器（WebKit 原生从 ScreenProperties 算出，不注入脚本）。
    func testPageScreenFollowsTargetDisplayWithoutAdvancedPrivacy() throws {
        _ = NSApplication.shared
        let studio = try XCTUnwrap(MacDeviceModel.preset("mac-studio-m3-ultra"))
        _ = DeviceSimulation.installDisplayOverride(for: studio, diagnostics: SPIDiagnostics())
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: window.contentView!.bounds, configuration: WKWebViewConfiguration())
        window.contentView = webView
        window.orderFront(nil)
        defer { window.close() }
        webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://example.invalid/"))
        let done = expectation(description: "evaluated")
        var result: [Int] = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            webView.evaluateJavaScript("[screen.width, screen.height, screen.availWidth, screen.availHeight]") { value, _ in
                result = (value as? [NSNumber])?.map(\.intValue) ?? []
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 15)
        XCTAssertEqual(result, [2560, 1440, 2560, 1415])
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
