import Darwin
import XCTest
import WebKit
import SafarierObjCSupport
@testable import SafarierWebKit

/// 直接调用 ObjC 层的 `SFRSetFontAllowList`：类型检查不通过时不发任何消息、不崩溃；空名单什么都不做。
@MainActor
final class SFRSetFontAllowListTests: XCTestCase {
    static let verifiedPrefix = "20621.3.11"

    /// WKWebView 所在 bundle 的 CFBundleVersion。
    static var webKitBundleVersion: String? {
        Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// 本进程里 WebKit 是否导出了全部需要的 C 函数（缺了会先报 MissingSymbol，不会走到类检查）。
    private static var hasAllExports: Bool {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        let exports: [String] = [SFRSymbolDecoder.decode([0x0D, 0x11, 0x19, 0x35, 0x34, 0x2E, 0x3F, 0x22, 0x2E, 0x09, 0x3F, 0x2E, 0x1C, 0x35, 0x34, 0x2E, 0x1B, 0x36, 0x36, 0x35, 0x2D, 0x16, 0x33, 0x29, 0x2E]), SFRSymbolDecoder.decode([0x0D, 0x11, 0x19, 0x35, 0x34, 0x2E, 0x3F, 0x22, 0x2E, 0x1D, 0x3F, 0x2E, 0x0E, 0x23, 0x2A, 0x3F, 0x13, 0x1E]), SFRSymbolDecoder.decode([0x0D, 0x11, 0x1D, 0x3F, 0x2E, 0x0E, 0x23, 0x2A, 0x3F, 0x13, 0x1E]), SFRSymbolDecoder.decode([0x0D, 0x11, 0x1B, 0x28, 0x28, 0x3B, 0x23, 0x19, 0x28, 0x3F, 0x3B, 0x2E, 0x3F]), SFRSymbolDecoder.decode([0x0D, 0x11, 0x09, 0x2E, 0x28, 0x33, 0x34, 0x3D, 0x19, 0x28, 0x3F, 0x3B, 0x2E, 0x3F, 0x0D, 0x33, 0x2E, 0x32, 0x0F, 0x0E, 0x1C, 0x62, 0x19, 0x09, 0x2E, 0x28, 0x33, 0x34, 0x3D]), SFRSymbolDecoder.decode([0x0D, 0x11, 0x08, 0x3F, 0x36, 0x3F, 0x3B, 0x29, 0x3F])]
        return exports.allSatisfy { dlsym(rtldDefault, $0) != nil }
    }

    private func call(_ pool: Any?, _ names: [String]) -> (SFRCallStatus, String?) {
        var detail: NSString?
        let status = SFRSetFontAllowList(pool, names, &detail)
        return (status, detail as String?)
    }

    /// 要直接构造 进程池对象（macOS 12 起标为弃用，但 引擎上下文 仍是它）。
    @available(macOS, deprecated: 12.0)
    func testNonPoolObjectsAreMissingClassWithoutCrash() throws {
        guard Self.hasAllExports else {
            // 没有导出时一律先报 MissingSymbol。
            XCTAssertEqual(call(try SPIRuntimeBridge.newInstance(className: SPIPrivacyAdapter.Symbols.webKit.processPoolClass).get(), ["Helvetica"]).0, .missingSymbol)
            throw XCTSkip("本机引擎缺少字体允许集合相关导出")
        }
        let candidates: [(String, Any?)] = [
            ("nil", nil),
            ("NSObject", NSObject()),
            ("WKPreferences", WKPreferences()),
            ("WKWebsiteDataStore", WKWebsiteDataStore.nonPersistent()),
        ]
        for (label, object) in candidates {
            let (status, detail) = call(object, ["Helvetica"])
            XCTAssertEqual(status, .missingClass, "\(label): \(detail ?? "")")
            XCTAssertNotNil(detail, label)
        }
    }

    func testEmptyNamesReturnOKWithoutCalling() {
        // nil 进程池本来过不了类检查；返回 OK + "empty" 说明根本没走到检查和调用。
        let (status, detail) = call(nil, [])
        XCTAssertEqual(status, .OK)
        XCTAssertEqual(detail, "empty")
        XCTAssertEqual(call(NSObject(), []).1, "empty")
    }

    @available(macOS, deprecated: 12.0)
    func testRealProcessPoolOnVerifiedWebKit() throws {
        let version = Self.webKitBundleVersion ?? "未知"
        guard version.hasPrefix(Self.verifiedPrefix) else {
            throw XCTSkip("WebKit \(version) 不是已验证的 \(Self.verifiedPrefix)")
        }
        let (status, detail) = call(try SPIRuntimeBridge.newInstance(className: SPIPrivacyAdapter.Symbols.webKit.processPoolClass).get(), ["Helvetica"])
        XCTAssertEqual(status, .OK, detail ?? "")
        XCTAssertEqual(detail, "已设置 1 个名字")
    }
}
