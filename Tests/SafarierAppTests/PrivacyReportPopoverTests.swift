import XCTest
import AppKit
import SafarierCore
@testable import Safarier

@MainActor
final class PrivacyReportPopoverTests: XCTestCase {
    func testSiteSubtitleUsesDomainOrStartPageFallback() {
        XCTAssertEqual(PrivacyReportPopover.siteSubtitle(for: nil), "当前环境隐私护盾已就绪")
        XCTAssertEqual(PrivacyReportPopover.siteSubtitle(for: URL(string: "about:blank")), "当前环境隐私护盾已就绪")
        XCTAssertEqual(PrivacyReportPopover.siteSubtitle(for: URL(string: "https://www.ippure.com/check")), "ippure.com")
        XCTAssertEqual(PrivacyReportPopover.siteSubtitle(for: URL(string: "https://browserleaks.com/canvas")), "browserleaks.com")
    }

    func testMakeViewControllerBuilds340ptPopoverWithExpectedSections() {
        let profile = Profile(
            name: "美区住宅环境",
            mode: .ephemeral,
            languages: ["en-US", "en"],
            timeZoneIdentifier: "America/Los_Angeles"
        )
        var report = PrivacyCapabilityReport()
        report.set(.active("AFP"), for: .advancedPrivacyProtections)
        report.set(.active("ephemeral"), for: .dataIsolation)
        report.set(.active("socks5"), for: .proxy)

        let controller = PrivacyReportPopover.makeViewController(
            profile: profile,
            currentURL: URL(string: "https://www.ippure.com/"),
            report: report,
            outboundDescription: "SOCKS5 127.0.0.1:1080"
        )

        XCTAssertEqual(controller.preferredContentSize.width, 340)
        XCTAssertGreaterThan(controller.preferredContentSize.height, 200)

        let labels = collectTexts(in: controller.view)
        XCTAssertTrue(labels.contains("隐私报告"))
        XCTAssertTrue(labels.contains("ippure.com"))
        XCTAssertTrue(labels.contains("当前环境：美区住宅环境"))
        XCTAssertTrue(labels.contains("Safari 原生防指纹保护"))
        XCTAssertTrue(labels.contains("独立网站数据沙盒"))
        XCTAssertTrue(labels.contains("出站代理通道"))
        XCTAssertTrue(labels.contains { $0.contains("系统字体白名单隔离") && $0.contains("区域时区引擎同步") })
        XCTAssertTrue(labels.contains { $0.contains("SOCKS5 127.0.0.1:1080") && $0.contains("Fail-Closed") })

        let buttons = collectButtons(in: controller.view)
        XCTAssertTrue(buttons.contains { $0.title == "拷贝环境诊断摘要" })
    }

    func testCopyDiagnosticsButtonDispatchesBrowserAction() {
        _ = NSApplication.shared
        let profile = Profile(name: "测试环境", mode: .persistent)
        let controller = PrivacyReportPopover.makeViewController(
            profile: profile,
            currentURL: nil,
            report: PrivacyCapabilityReport(),
            outboundDescription: "直连"
        )
        let button = collectButtons(in: controller.view).first { $0.title == "拷贝环境诊断摘要" }
        XCTAssertNotNil(button)
        XCTAssertNotNil(button?.target)
        XCTAssertNotNil(button?.action)
        if let action = button?.action, let target = button?.target as? NSObject {
            XCTAssertTrue(target.responds(to: action))
        }
    }

    private func collectTexts(in view: NSView) -> [String] {
        var result: [String] = []
        if let field = view as? NSTextField {
            result.append(field.stringValue)
        }
        for subview in view.subviews {
            result.append(contentsOf: collectTexts(in: subview))
        }
        return result
    }

    private func collectButtons(in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        if let button = view as? NSButton {
            result.append(button)
        }
        for subview in view.subviews {
            result.append(contentsOf: collectButtons(in: subview))
        }
        return result
    }
}
