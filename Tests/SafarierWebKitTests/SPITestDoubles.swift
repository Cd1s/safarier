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

/// 照引擎的总开关算法：四个高级隐私保护位（0x1c1）齐了才是 YES。
final class EngineLikePolicyPreferences: NSObject {
    var stored: UInt

    init(stored: UInt = 0) {
        self.stored = stored
    }

    @objc(safarierMockPolicy) var policy: UInt { stored }
    @objc(setSafarierMockPolicy:) func setPolicy(_ value: UInt) { stored = value }
    @objc(safarierMockPolicyEnabled) var policyEnabled: Bool { stored & 0x1C1 == 0x1C1 }
}

/// 位掩码照常写入、回读，但总开关一直是 NO。
final class SwitchOffPolicyPreferences: NSObject {
    var stored: UInt = 0

    @objc(safarierMockPolicy) var policy: UInt { stored }
    @objc(setSafarierMockPolicy:) func setPolicy(_ value: UInt) { stored = value }
    @objc(safarierMockPolicyEnabled) var policyEnabled: Bool { false }
}

/// 总开关的读法抛 NSException。
final class ThrowingSwitchPolicyPreferences: NSObject {
    var stored: UInt = 0

    @objc(safarierMockPolicy) var policy: UInt { stored }
    @objc(setSafarierMockPolicy:) func setPolicy(_ value: UInt) { stored = value }
    @objc(safarierMockPolicyEnabled) var policyEnabled: Bool {
        NSException(name: .internalInconsistencyException, reason: "fake switch failure", userInfo: nil).raise()
        return false
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

/// 正常：Safari 专有接口的三个嵌入方开关。没有 Safari 行为默认值的读写接口（适配器应当跳过、保持默认）。
class FakeSafariAPIPreferences: NSObject {
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

/// 另外还有 Safari 的 5 个行为默认值，初值和裸 WKPreferences 一样（退格键后退开着，其余关着）。
final class FakeSafariBehaviorPreferences: FakeSafariAPIPreferences {
    var behaviors: [String: Bool] = ["backspace": true, "services": false, "tooltip": false, "telephone": false, "tiles": false]
    var ignoreBehaviorWrites = false

    private func set(_ key: String, _ value: Bool) { if !ignoreBehaviorWrites { behaviors[key] = value } }
    @objc(safarierMockBackspace) var backspace: Bool { behaviors["backspace"]! }
    @objc(setSafarierMockBackspace:) func setBackspace(_ value: Bool) { set("backspace", value) }
    @objc(safarierMockServices) var services: Bool { behaviors["services"]! }
    @objc(setSafarierMockServices:) func setServices(_ value: Bool) { set("services", value) }
    @objc(safarierMockTooltip) var tooltip: Bool { behaviors["tooltip"]! }
    @objc(setSafarierMockTooltip:) func setTooltip(_ value: Bool) { set("tooltip", value) }
    @objc(safarierMockTelephone) var telephone: Bool { behaviors["telephone"]! }
    @objc(setSafarierMockTelephone:) func setTelephone(_ value: Bool) { set("telephone", value) }
    @objc(safarierMockTiles) var tiles: Bool { behaviors["tiles"]! }
    @objc(setSafarierMockTiles:) func setTiles(_ value: Bool) { set("tiles", value) }
}

let mockSymbols: SPIPrivacyAdapter.Symbols = {
    var symbols = SPIPrivacyAdapter.Symbols.webKit
    symbols.networkPolicyGetter = "safarierMockPolicy"
    symbols.networkPolicySetter = "setSafarierMockPolicy:"
    symbols.networkPolicyEnabledGetter = "safarierMockPolicyEnabled"
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
    symbols.safariBehaviorSwitches = [
        ("safarierMockBackspace", "setSafarierMockBackspace:", "退格键不后退", false),
        ("safarierMockServices", "setSafarierMockServices:", "服务控件", true),
        ("safarierMockTooltip", "setSafarierMockTooltip:", "截断文字悬停提示", true),
        ("safarierMockTelephone", "setSafarierMockTelephone:", "电话号码识别", true),
        ("safarierMockTiles", "setSafarierMockTiles:", "积极保留图块", true),
    ]
    return symbols
}()
