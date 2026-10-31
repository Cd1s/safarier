import XCTest
import WebKit
import SafarierCore
@testable import SafarierWebKit

@MainActor
final class SPIRuntimeBridgeTests: XCTestCase {
    func testUnsignedIntegerRoundTrip() throws {
        let target = FakePolicyPreferences(stored: 0x2)
        XCTAssertEqual(try SPIRuntimeBridge.getUInt(mockSymbols.networkPolicyGetter, on: target).get(), 0x2)
        try SPIRuntimeBridge.setUInt(0x1C0, mockSymbols.networkPolicySetter, on: target).get()
        XCTAssertEqual(target.stored, 0x1C0)
    }

    func testMissingSelectorIsReportedWithoutCalling() {
        guard case .failure(let failure) = SPIRuntimeBridge.setBool(false, mockSymbols.peerConnectionSetter, on: EmptyObject()) else {
            return XCTFail("应当失败")
        }
        XCTAssertTrue(failure.isUnsupported)
        guard case .missingSelector = failure else { return XCTFail("\(failure)") }
    }

    func testSignatureMismatchIsRejectedBeforeCalling() {
        let target = WrongSignaturePeerConnectionPreferences()
        guard case .failure(.signatureMismatch(let text)) = SPIRuntimeBridge.setBool(false, mockSymbols.peerConnectionSetter, on: target) else {
            return XCTFail("应当是签名不符")
        }
        XCTAssertFalse(target.called)
        XCTAssertTrue(text.contains("参数类型"), text)

        // BOOL getter 当成 NSUInteger 读，同样拒绝。
        guard case .failure(.signatureMismatch) = SPIRuntimeBridge.getUInt(mockSymbols.peerConnectionGetter, on: FakePeerConnectionPreferences()) else {
            return XCTFail("应当是签名不符")
        }
    }

    func testObjectiveCExceptionIsCaught() {
        guard case .failure(.exception(let text)) = SPIRuntimeBridge.setUInt(1, mockSymbols.networkPolicySetter, on: ThrowingPolicyPreferences()) else {
            return XCTFail("应当捕获异常")
        }
        XCTAssertTrue(text.contains("NSInternalInconsistencyException"), text)
    }

    func testObjectAccessorsAndInstanceCreation() throws {
        let configuration = try SPIRuntimeBridge.newInstance(className: mockSymbols.processPoolConfigurationClass).get()
        try SPIRuntimeBridge.setObject("Asia/Tokyo" as NSString, mockSymbols.timeZoneSetter, on: configuration).get()
        XCTAssertEqual(try SPIRuntimeBridge.getObject(mockSymbols.timeZoneGetter, on: configuration).get() as? String, "Asia/Tokyo")

        let pool = try SPIRuntimeBridge.allocInit(className: mockSymbols.processPoolClass, initializer: mockSymbols.processPoolInitializer, argument: configuration).get()
        XCTAssertTrue((pool as? FakePool)?.storedConfiguration === configuration)
    }

    func testMissingClassAndInitializer() {
        guard case .failure(.missingClass) = SPIRuntimeBridge.newInstance(className: "SafarierNoSuchClass") else {
            return XCTFail("应当找不到类")
        }
        guard case .failure(.missingSelector) = SPIRuntimeBridge.allocInit(className: mockSymbols.processPoolConfigurationClass, initializer: mockSymbols.processPoolInitializer, argument: NSObject()) else {
            return XCTFail("应当找不到初始化器")
        }
    }

    func testSymbolDecoderHandlesEmptyASCIIAndUTF8() {
        XCTAssertEqual(SFRSymbolDecoder.decode([]), "")
        XCTAssertEqual(SFRSymbolDecoder.decode([0x29, 0x3B, 0x3C, 0x3F]), "safe")
        XCTAssertEqual(SFRSymbolDecoder.decode([0xBF, 0xCE, 0xCA]), "唐")
        XCTAssertEqual(SFRSymbolDecoder.decode([0xA5]), "")
        XCTAssertEqual(SFRSymbolDecoder.decode(Array(repeating: 0x3B, count: 1024)), String(repeating: "a", count: 1024))
    }

    func testDecodedEngineSymbolsWorkWithRealWebKit() throws {
        let symbols = SPIPrivacyAdapter.Symbols.webKit
        let names = [
            symbols.networkPolicyGetter, symbols.networkPolicySetter,
            symbols.processPoolConfigurationClass, symbols.processPoolClass,
            symbols.processPoolGetter, symbols.processPoolSetter,
            symbols.processPoolInitializer, symbols.processPoolConfigurationGetter,
            symbols.timeZoneGetter, symbols.timeZoneSetter,
            symbols.peerConnectionGetter, symbols.peerConnectionSetter,
            symbols.featuresGetter, symbols.featureGetter, symbols.featureSetter,
            symbols.userInstalledFontsGetter, symbols.userInstalledFontsSetter,
            DeviceSimulation.setter, DeviceSimulation.getter,
            WebViewSPI.textZoomGetter, WebViewSPI.textZoomSetter,
            WebViewSPI.inspectorGetter, WebViewSPI.mainResourceData,
        ] + symbols.webGPUFeatureKeys + symbols.safariAPISwitches.flatMap { [$0.getter, $0.setter] }
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
        XCTAssertNotNil(NSClassFromString(symbols.processPoolConfigurationClass))
        XCTAssertNotNil(NSClassFromString(symbols.processPoolClass))

        let configuration = WKWebViewConfiguration()
        let policy = try SPIRuntimeBridge.getUInt(symbols.networkPolicyGetter, on: configuration.defaultWebpagePreferences).get()
        try SPIRuntimeBridge.setUInt(policy, symbols.networkPolicySetter, on: configuration.defaultWebpagePreferences).get()
        try SPIRuntimeBridge.setBool(false, symbols.peerConnectionSetter, on: configuration.preferences).get()
        XCTAssertFalse(try SPIRuntimeBridge.getBool(symbols.peerConnectionGetter, on: configuration.preferences).get())

        let webView = WKWebView(frame: .zero, configuration: configuration)
        try SPIRuntimeBridge.setDouble(1, DeviceSimulation.setter, on: webView).get()
        XCTAssertEqual(try SPIRuntimeBridge.getDouble(DeviceSimulation.getter, on: webView).get(), 1)
        defer { _ = SPIRuntimeBridge.setDouble(0, DeviceSimulation.setter, on: webView) }
        XCTAssertTrue(WebViewSPI.setTextZoomFactor(1.25, on: webView))
        XCTAssertEqual(WebViewSPI.textZoomFactor(of: webView), 1.25)
        XCTAssertTrue(WebViewSPI.hasInspector(webView))
        XCTAssertTrue(webView.responds(to: NSSelectorFromString(WebViewSPI.mainResourceData)))
    }

    /// 本轮新加的接口在本机 WebKit 上都在、签名对：数据存储配置、智能防跟踪、Safari 行为默认值、高级隐私保护总开关。
    func testSafariParitySymbolsMatchRealWebKitSignatures() throws {
        func encoding(_ cls: AnyClass, _ name: String) -> String? {
            class_getInstanceMethod(cls, NSSelectorFromString(name)).flatMap { method_getTypeEncoding($0) }.map { String(cString: $0) }
        }
        let store = DataStoreManager.Symbols.webKit
        let configuration: AnyClass = try XCTUnwrap(NSClassFromString(store.configurationClass), "本机 WebKit 应当有数据存储配置类")
        XCTAssertEqual(encoding(configuration, store.nonPersistentInitializer), "@16@0:8")
        for item in store.configurationSwitches {
            XCTAssertEqual(encoding(configuration, item.getter), "B16@0:8", item.label)
            XCTAssertEqual(encoding(configuration, item.setter), "v20@0:8B16", item.label)
        }
        XCTAssertEqual(encoding(WKWebsiteDataStore.self, store.storeInitializer), "@24@0:8@16")
        XCTAssertEqual(encoding(WKWebsiteDataStore.self, store.statisticsGetter), "B16@0:8")
        XCTAssertEqual(encoding(WKWebsiteDataStore.self, store.statisticsSetter), "v20@0:8B16")

        let symbols = SPIPrivacyAdapter.Symbols.webKit
        XCTAssertEqual(encoding(WKWebpagePreferences.self, symbols.networkPolicyEnabledGetter), "B16@0:8")
        let bare = WKPreferences()
        for item in symbols.safariBehaviorSwitches {
            XCTAssertEqual(encoding(WKPreferences.self, item.getter), "B16@0:8", item.label)
            XCTAssertEqual(encoding(WKPreferences.self, item.setter), "v20@0:8B16", item.label)
            XCTAssertEqual(try SPIRuntimeBridge.getBool(item.getter, on: bare).get(), !item.value, "裸 WKPreferences 的默认值和 Safari 相反：\(item.label)")
        }
    }

    /// 无参初始化：只调用 init 家族、返回对象、没有参数的方法。
    func testAllocInitWithoutArgumentsChecksFamilyAndSignature() throws {
        XCTAssertTrue(try SPIRuntimeBridge.allocInit(className: "SafarierTestPoolConfiguration", initializer: "init").get() is FakePoolConfiguration)
        guard case .failure(.missingClass) = SPIRuntimeBridge.allocInit(className: "_SafarierNoSuchClass", initializer: "init") else {
            return XCTFail("类不在")
        }
        guard case .failure(.missingSelector) = SPIRuntimeBridge.allocInit(className: "SafarierTestPoolConfiguration", initializer: "copy") else {
            return XCTFail("不是 init 家族的方法不调用")
        }
        guard case .failure(.signatureMismatch) = SPIRuntimeBridge.allocInit(className: "SafarierTestPool", initializer: "initWithSafarierMockConfiguration:") else {
            return XCTFail("要参数的初始化方法不调用")
        }
    }

}
