import Foundation
import SafarierObjCSupport

/// 动态调用原生引擎接口失败的原因。前三种表示本机 WebKit 没有（或不是预期形状的）接口，没有发生调用；
/// `exception` 表示调用了但抛出了 NSException（已在 ObjC 层接住）。
public enum SPICallFailure: Error, Equatable, CustomStringConvertible {
    case missingClass(String)
    case missingSelector(String)
    case signatureMismatch(String)
    case exception(String)

    /// 接口不存在或签名不符：本机做不到，而不是调用出错。
    public var isUnsupported: Bool {
        switch self {
        case .missingClass, .missingSelector, .signatureMismatch: return true
        case .exception: return false
        }
    }

    public var description: String {
        switch self {
        case .missingClass(let text), .missingSelector(let text), .signatureMismatch(let text), .exception(let text):
            return text
        }
    }
}

/// SafarierObjCSupport 的 Swift 包装：只按名字（字符串）找接口，不静态链接任何引擎符号。
enum SPIRuntimeBridge {
    static func setUInt(_ value: UInt, _ selector: String, on target: NSObject) -> Result<Void, SPICallFailure> {
        var detail: NSString?
        return result(SFRSetUnsignedInteger(target, selector, value, &detail), detail) { () }
    }

    static func getUInt(_ selector: String, on target: NSObject) -> Result<UInt, SPICallFailure> {
        var value: UInt = 0
        var detail: NSString?
        let status = SFRGetUnsignedInteger(target, selector, &value, &detail)
        return result(status, detail) { value }
    }

    static func setBool(_ value: Bool, _ selector: String, on target: NSObject) -> Result<Void, SPICallFailure> {
        var detail: NSString?
        return result(SFRSetBool(target, selector, value, &detail), detail) { () }
    }

    static func getBool(_ selector: String, on target: NSObject) -> Result<Bool, SPICallFailure> {
        var value: ObjCBool = false
        var detail: NSString?
        let status = SFRGetBool(target, selector, &value, &detail)
        return result(status, detail) { value.boolValue }
    }

    static func setDouble(_ value: Double, _ selector: String, on target: NSObject) -> Result<Void, SPICallFailure> {
        var detail: NSString?
        return result(SFRSetDouble(target, selector, value, &detail), detail) { () }
    }

    static func getDouble(_ selector: String, on target: NSObject) -> Result<Double, SPICallFailure> {
        var value: Double = 0
        var detail: NSString?
        let status = SFRGetDouble(target, selector, &value, &detail)
        return result(status, detail) { value }
    }

    static func setBool(_ value: Bool, _ selector: String, with argument: AnyObject, on target: NSObject) -> Result<Void, SPICallFailure> {
        var detail: NSString?
        return result(SFRSetBoolWithObject(target, selector, value, argument, &detail), detail) { () }
    }

    static func getBool(_ selector: String, with argument: AnyObject, on target: NSObject) -> Result<Bool, SPICallFailure> {
        var value: ObjCBool = false
        var detail: NSString?
        let status = SFRGetBoolWithObject(target, selector, argument, &value, &detail)
        return result(status, detail) { value.boolValue }
    }

    static func installDisplayOverride(
        p3: Bool, hdr: Bool, maxHeadroom: Double, currentHeadroom: Double,
        screenWidth: Double, screenHeight: Double, availHeight: Double
    ) -> Result<Void, SPICallFailure> {
        var detail: NSString?
        let status = SFRInstallDisplayOverride(p3, hdr, maxHeadroom, currentHeadroom, screenWidth, screenHeight, availHeight, &detail)
        return result(status, detail) { () }
    }

    static func hostVisibleFrame() -> CGRect {
        SFRHostVisibleFrame()
    }

    static func removeDisplayOverride() {
        SFRRemoveDisplayOverride()
    }

    static func setObject(_ value: AnyObject?, _ selector: String, on target: NSObject) -> Result<Void, SPICallFailure> {
        var detail: NSString?
        return result(SFRSetObject(target, selector, value, &detail), detail) { () }
    }

    static func getObject(_ selector: String, on target: NSObject) -> Result<AnyObject?, SPICallFailure> {
        var value: AnyObject?
        var detail: NSString?
        let status = SFRGetObject(target, selector, &value, &detail)
        return result(status, detail) { value }
    }

    static func callVoid(_ selector: String, on target: NSObject) -> Result<Void, SPICallFailure> {
        var detail: NSString?
        return result(SFRCallVoid(target, selector, &detail), detail) { () }
    }

    static func callWithDataCompletion(
        _ selector: String, on target: NSObject, completion: @escaping (Data?, Error?) -> Void
    ) -> Result<Void, SPICallFailure> {
        var detail: NSString?
        return result(SFRCallWithDataCompletion(target, selector, { data, error in completion(data, error) }, &detail), detail) { () }
    }

    static func newInstance(className: String) -> Result<NSObject, SPICallFailure> {
        var instance: AnyObject?
        var detail: NSString?
        let status = SFRNewInstance(className, &instance, &detail)
        return result(status, detail) { instance }.flatMap(Self.asObject(className))
    }

    static func allocInit(className: String, initializer: String, argument: AnyObject) -> Result<NSObject, SPICallFailure> {
        var instance: AnyObject?
        var detail: NSString?
        let status = SFRAllocInitWithObject(className, initializer, argument, &instance, &detail)
        return result(status, detail) { instance }.flatMap(Self.asObject(className))
    }

    private static func asObject(_ className: String) -> (AnyObject?) -> Result<NSObject, SPICallFailure> {
        { value in
            guard let object = value as? NSObject else {
                return .failure(.exception("engineClass 实例不是 NSObject"))
            }
            return .success(object)
        }
    }

    private static func result<T>(_ status: SFRCallStatus, _ detail: NSString?, _ success: () -> T) -> Result<T, SPICallFailure> {
        let text = (detail as String?) ?? "未知原因"
        switch status {
        case .OK: return .success(success())
        case .missingClass: return .failure(.missingClass(text))
        case .missingSelector: return .failure(.missingSelector(text))
        case .signatureMismatch: return .failure(.signatureMismatch(text))
        case .exception: return .failure(.exception(text))
        // 这里包装的调用不会返回 MissingSymbol（只有 SFRSetFontAllowList 会，它不走这里）；按接口不存在处理。
        case .missingSymbol: return .failure(.missingClass(text))
        @unknown default: return .failure(.exception("未知状态 \(status.rawValue)：\(text)"))
        }
    }
}
