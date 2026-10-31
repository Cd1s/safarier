import Foundation
@testable import SafarierWebKit

// 合成的引擎测试接口：用独立的 selector 验证签名和降级，不向测试产物写入引擎名字。

/// 正常的读写测试对象。
final class FakePolicyPreferences: NSObject {
    var stored: UInt
    var ignoreWrites = false
    private(set) var writes: [UInt] = []

    init(stored: UInt = 0) {
        self.stored = stored
    }

    @objc(safarierMockPolicy) var policy: UInt { stored }

    @objc(setSafarierMockPolicy:) func setPolicy(_ value: UInt) {
        writes.append(value)
        if !ignoreWrites { stored = value }
    }
}

/// setter 抛 NSException。
final class ThrowingPolicyPreferences: NSObject {
    @objc(safarierMockPolicy) var policy: UInt { 0 }

    @objc(setSafarierMockPolicy:) func setPolicy(_ value: UInt) {
        NSException(name: .internalInconsistencyException, reason: "fake policy failure", userInfo: nil).raise()
    }
}

/// 正常的读写测试对象。
final class FakePeerConnectionPreferences: NSObject {
    var enabled = true
    var ignoreWrites = false
    private(set) var writeCount = 0

    @objc(safarierMockPeerConnection) var peerConnectionEnabled: Bool { enabled }

    @objc(setSafarierMockPeerConnection:) func setPeerConnectionEnabled(_ value: Bool) {
        writeCount += 1
        if !ignoreWrites { enabled = value }
    }
}

/// selector 名对，但参数/返回值是对象而不是 BOOL：必须拒绝调用。
final class WrongSignaturePeerConnectionPreferences: NSObject {
    private(set) var called = false

    @objc(safarierMockPeerConnection) var peerConnectionEnabled: NSString { "yes" }

    @objc(setSafarierMockPeerConnection:) func setPeerConnectionEnabled(_ value: NSString) {
        called = true
    }
}

/// 什么原生引擎接口都没有。
final class EmptyObject: NSObject {}

@objc(SafarierTestPoolConfiguration)
final class FakePoolConfiguration: NSObject {
    @objc(safarierMockTimeZone) var engineTimeZone: NSString?
}

@objc(SafarierTestThrowingPoolConfiguration)
final class ThrowingPoolConfiguration: NSObject {
    @objc(safarierMockTimeZone) var engineTimeZone: NSString? {
        get { nil }
        set { NSException(name: .invalidArgumentException, reason: "fake time zone failure", userInfo: nil).raise() }
    }
}

/// 按测试初始化器创建，并读回配置对象。
@objc(SafarierTestPool)
final class FakePool: NSObject {
    let storedConfiguration: NSObject

    @objc(initWithSafarierMockConfiguration:) init(configuration: NSObject) {
        storedConfiguration = configuration
        super.init()
    }

    @objc(safarierMockConfiguration) var configuration: NSObject { storedConfiguration }
}

/// 正常：Safari 专有接口的三个嵌入方开关。
final class FakeSafariAPIPreferences: NSObject {
    var applePayDisclosure = true
    var ignoreDisclosureWrites = false
    var applePay = false
    var push = false
    var mediaDevices = false
    var userInstalledFonts = true
    var ignoreWrites = false

    @objc(safarierMockApplePayDisclosure) var disclosureAllowed: Bool { applePayDisclosure }
    @objc(setSafarierMockApplePayDisclosure:) func setDisclosureAllowed(_ value: Bool) {
        if !ignoreDisclosureWrites { applePayDisclosure = value }
    }
    @objc(safarierMockApplePay) var applePayEnabled: Bool { applePay }
    @objc(setSafarierMockApplePay:) func setApplePayEnabled(_ value: Bool) { if !ignoreWrites { applePay = value } }
    @objc(safarierMockPushAPI) var pushAPIEnabled: Bool { push }
    @objc(setSafarierMockPushAPI:) func setPushAPIEnabled(_ value: Bool) { if !ignoreWrites { push = value } }
    @objc(safarierMockMediaDevices) var mediaDevicesEnabled: Bool { mediaDevices }
    @objc(setSafarierMockMediaDevices:) func setMediaDevicesEnabled(_ value: Bool) { if !ignoreWrites { mediaDevices = value } }
    @objc(safarierMockUserFonts) var shouldAllowUserInstalledFonts: Bool { userInstalledFonts }
    @objc(setSafarierMockUserFonts:) func setShouldAllowUserInstalledFonts(_ value: Bool) { if !ignoreWrites { userInstalledFonts = value } }
}

let mockSymbols: SPIPrivacyAdapter.Symbols = {
    var symbols = SPIPrivacyAdapter.Symbols.webKit
    symbols.networkPolicyGetter = "safarierMockPolicy"
    symbols.networkPolicySetter = "setSafarierMockPolicy:"
    symbols.peerConnectionGetter = "safarierMockPeerConnection"
    symbols.peerConnectionSetter = "setSafarierMockPeerConnection:"
    symbols.timeZoneGetter = "safarierMockTimeZone"
    symbols.timeZoneSetter = "setSafarierMockTimeZone:"
    symbols.processPoolInitializer = "initWithSafarierMockConfiguration:"
    symbols.processPoolConfigurationGetter = "safarierMockConfiguration"
    symbols.processPoolClass = "SafarierTestPool"
    symbols.processPoolConfigurationClass = "SafarierTestPoolConfiguration"
    symbols.applePayDisclosureGetter = "safarierMockApplePayDisclosure"
    symbols.applePayDisclosureSetter = "setSafarierMockApplePayDisclosure:"
    symbols.userInstalledFontsGetter = "safarierMockUserFonts"
    symbols.userInstalledFontsSetter = "setSafarierMockUserFonts:"
    symbols.safariAPISwitches = [
        ("safarierMockApplePay", "setSafarierMockApplePay:", "ApplePaySession"),
        ("safarierMockPushAPI", "setSafarierMockPushAPI:", "PushManager"),
        ("safarierMockMediaDevices", "setSafarierMockMediaDevices:", "navigator.mediaDevices"),
    ]
    return symbols
}()
