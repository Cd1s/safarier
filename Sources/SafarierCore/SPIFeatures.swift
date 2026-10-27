import Foundation

/// profile 开启的原生引擎接口能力。新建环境默认开启 `defaultFeatures`；只有开启的项才会交给 SPIPrivacyAdapter。
/// 命令行和 JSON 里用短名：afp、tz、webrtc、safari、webgpu、fontlist。
public struct SPIFeatures: OptionSet, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Safari 无痕同款的高级隐私保护（Canvas/WebGL/Audio 读回噪声等），M0-7。
    public static let fingerprintingProtections = SPIFeatures(rawValue: 1 << 0)
    /// 引擎层时区覆盖（替代传不到 WebContent 的 TZ），M0-8。
    public static let engineTimeZone = SPIFeatures(rawValue: 1 << 1)
    /// 关闭 WebRTC（RTCPeerConnection 不再暴露），M0-9。
    public static let disableWebRTC = SPIFeatures(rawValue: 1 << 2)
    /// Safari 作为浏览器才打开的网页接口：ApplePaySession、PushManager、navigator.mediaDevices；
    /// 以及和 Safari 一样关闭用户安装字体。
    /// 普通 WKWebView 应用默认没有，网页一查就知道不是 Safari。
    public static let safariAPIs = SPIFeatures(rawValue: 1 << 3)
    /// WebGPU（navigator.gpu）。注意：真 Safari 26.2 / 27 在 macOS 15 上都没有 navigator.gpu（2026-10-24 本机实测 Safari 27），
    /// 打开后反而和真 Safari 不一致，所以不默认开。
    public static let webGPU = SPIFeatures(rawValue: 1 << 4)
    /// 按 Profile 语言收窄网页能按名字用的字体（原生引擎桥接）：英文、泰语等环境里网页查不到
    /// 宿主机按中日韩语言下载的字体包（如苹方），和真英文 Mac 一致。只在已验证的 WebKit 版本上尝试，失败时不改变行为。
    public static let fontAllowlist = SPIFeatures(rawValue: 1 << 5)

    /// 新建环境默认开启的项：高级隐私保护、引擎层时区、Safari 专有接口与字体、按语言收窄字体。
    /// WebRTC 关闭和 WebGPU 和真 Safari 的默认不同，不默认开。
    public static let defaultFeatures: SPIFeatures = [.fingerprintingProtections, .engineTimeZone, .safariAPIs, .fontAllowlist]

    /// `--spi all` 打开的集合。
    public static let all: SPIFeatures = [.fingerprintingProtections, .engineTimeZone, .disableWebRTC, .safariAPIs, .webGPU, .fontAllowlist]

    public static let tokens: [(name: String, feature: SPIFeatures)] = [
        ("afp", .fingerprintingProtections),
        ("tz", .engineTimeZone),
        ("webrtc", .disableWebRTC),
        ("safari", .safariAPIs),
        ("webgpu", .webGPU),
        ("fontlist", .fontAllowlist),
    ]

    /// 接受 `all`、`none`、`default`，或逗号分隔的短名（如 `afp,tz,safari`）。
    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch trimmed {
        case "all":
            self = .all
            return
        case "none":
            self = []
            return
        case "default":
            self = .defaultFeatures
            return
        case "":
            throw SPIFeaturesParseError.empty
        default:
            break
        }
        var features: SPIFeatures = []
        for token in trimmed.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !token.isEmpty {
            guard let match = Self.tokens.first(where: { $0.name == token }) else {
                throw SPIFeaturesParseError.unknownToken(token)
            }
            features.insert(match.feature)
        }
        self = features
    }

    public var tokenList: [String] {
        Self.tokens.filter { contains($0.feature) }.map(\.name)
    }

    /// `none` 或逗号分隔的短名（如 `afp,tz,webrtc,safari,webgpu,fontlist`），从不输出 `all`；能被 `init(parsing:)` 原样读回。
    public var description: String {
        isEmpty ? "none" : tokenList.joined(separator: ",")
    }
}

/// JSON 里存成短名数组，便于人读；不认识的短名忽略（等于不开启，保守）。
extension SPIFeatures: Codable {
    public init(from decoder: Decoder) throws {
        let names = try decoder.singleValueContainer().decode([String].self)
        self = names.reduce(into: []) { result, name in
            if let match = Self.tokens.first(where: { $0.name == name }) {
                result.insert(match.feature)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(tokenList)
    }
}

public enum SPIFeaturesParseError: Error, Equatable {
    case empty
    case unknownToken(String)
}
