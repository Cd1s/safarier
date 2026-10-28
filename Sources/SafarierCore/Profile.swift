import Foundation

/// Profile 的数据模式。
/// - persistent：绑定 `WKWebsiteDataStore(forIdentifier: profile.id)`，数据落盘且跨启动保留。
/// - ephemeral：`WKWebsiteDataStore.nonPersistent()`，仅存活于 Runner 窗口生命周期内。
public enum ProfileMode: String, Codable, Sendable, CaseIterable {
    case persistent
    case ephemeral
}

/// 本地环境配置。独立代理、订阅节点、自定义 sing-box 出站互斥。
public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var mode: ProfileMode
    public var proxyID: UUID?
    public let createdAt: Date
    /// BCP-47 语言标签，如 ["en-US", "en"]；空数组表示跟随系统。
    public var languages: [String]
    /// IANA 时区标识，如 "America/Los_Angeles"；nil 表示跟随系统。
    public var timeZoneIdentifier: String?
    /// 语言跟随代理：Runner 启动时按出口 IP 的国家自动匹配语言（此时 `languages` 不用）。
    public var followProxyLanguages: Bool
    /// 时区跟随代理：Runner 启动时按出口 IP 的国家自动匹配时区（此时 `timeZoneIdentifier` 不用）。
    public var followProxyTimeZone: Bool
    public var startURL: URL?
    public var notes: String
    /// 开启的原生引擎接口能力。新建时默认 `SPIFeatures.defaultFeatures`；旧 JSON 没有这个字段时是空（保持当时的行为）。
    public var spi: SPIFeatures
    /// 绑定的订阅。节点按名字找：订阅刷新后节点的 id 会变，名字通常不变；重名时取第一个。
    public var subscriptionID: UUID?
    public var nodeName: String?
    /// 单个 sing-box 出站对象，可能包含认证信息；运行时配置的生命周期不影响它。
    public var customOutboundJSON: String?
    /// `MacDeviceModel.id`；nil 表示跟随系统。
    public var deviceModel: String?

    public init(
        id: UUID = UUID(),
        name: String,
        mode: ProfileMode,
        proxyID: UUID? = nil,
        createdAt: Date = Date(),
        languages: [String] = [],
        timeZoneIdentifier: String? = nil,
        followProxyLanguages: Bool = false,
        followProxyTimeZone: Bool = false,
        startURL: URL? = nil,
        notes: String = "",
        spi: SPIFeatures = .defaultFeatures,
        subscriptionID: UUID? = nil,
        nodeName: String? = nil,
        deviceModel: String? = nil,
        customOutboundJSON: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.proxyID = proxyID
        self.createdAt = createdAt
        self.languages = languages
        self.timeZoneIdentifier = timeZoneIdentifier
        self.followProxyLanguages = followProxyLanguages
        self.followProxyTimeZone = followProxyTimeZone
        self.startURL = startURL
        self.notes = notes
        self.spi = spi
        self.subscriptionID = subscriptionID
        self.nodeName = nodeName
        self.deviceModel = deviceModel
        self.customOutboundJSON = customOutboundJSON
    }

    /// 旧版 JSON 只有 id/name/mode/createdAt（及可选 proxyID），新增字段（含 spi）缺失时使用默认值。
    private enum CodingKeys: String, CodingKey {
        case id, name, mode, proxyID, createdAt, languages, timeZoneIdentifier, startURL, notes, spi
        case subscriptionID, nodeName, deviceModel, followProxyLanguages, followProxyTimeZone
        case customOutboundJSON
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mode = try container.decode(ProfileMode.self, forKey: .mode)
        proxyID = try container.decodeIfPresent(UUID.self, forKey: .proxyID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        languages = try container.decodeIfPresent([String].self, forKey: .languages) ?? []
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        startURL = try container.decodeIfPresent(URL.self, forKey: .startURL)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        spi = try container.decodeIfPresent(SPIFeatures.self, forKey: .spi) ?? []
        subscriptionID = try container.decodeIfPresent(UUID.self, forKey: .subscriptionID)
        nodeName = try container.decodeIfPresent(String.self, forKey: .nodeName)
        customOutboundJSON = try container.decodeIfPresent(String.self, forKey: .customOutboundJSON)
        deviceModel = try container.decodeIfPresent(String.self, forKey: .deviceModel)
        followProxyLanguages = try container.decodeIfPresent(Bool.self, forKey: .followProxyLanguages) ?? false
        followProxyTimeZone = try container.decodeIfPresent(Bool.self, forKey: .followProxyTimeZone) ?? false
    }

    // MARK: - 复制环境

    /// 名称上限，和 `validate()` 一致。
    public static let maxNameLength = 64

    /// 复制出来的环境名："原名 副本"，被占用时依次试"原名 副本 2"、"原名 副本 3"……
    /// 超过 64 个字符时截短原名，保留后缀。
    public static func duplicateName(for name: String, existing: Set<String>) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var counter = 1
        while true {
            let suffix = counter == 1 ? " 副本" : " 副本 \(counter)"
            let candidate = String(base.prefix(max(0, maxNameLength - suffix.count))) + suffix
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }

    /// 复制设置（出站、语言、时区、机型、原生引擎接口、备注……），用新的 id，所以有自己全新的网站数据目录，不带原环境的 Cookie。
    public func duplicated(name newName: String, id newID: UUID = UUID(), createdAt: Date = Date()) -> Profile {
        Profile(
            id: newID, name: newName, mode: mode, proxyID: proxyID, createdAt: createdAt,
            languages: languages, timeZoneIdentifier: timeZoneIdentifier,
            followProxyLanguages: followProxyLanguages, followProxyTimeZone: followProxyTimeZone,
            startURL: startURL, notes: notes, spi: spi,
            subscriptionID: subscriptionID, nodeName: nodeName, deviceModel: deviceModel,
            customOutboundJSON: customOutboundJSON
        )
    }

    public func validate() throws {
        if customOutboundJSON != nil, proxyID != nil || subscriptionID != nil || nodeName != nil {
            throw ProfileValidationError.conflictingOutbound
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            throw ProfileValidationError.emptyName
        }
        if trimmedName.count > 64 {
            throw ProfileValidationError.nameTooLong(trimmedName.count)
        }
        for tag in languages where tag.range(of: Self.languageTagPattern, options: .regularExpression) == nil {
            throw ProfileValidationError.invalidLanguageTag(tag)
        }
        if let identifier = timeZoneIdentifier, TimeZone(identifier: identifier) == nil {
            throw ProfileValidationError.unknownTimeZone(identifier)
        }
        if subscriptionID != nil {
            guard proxyID == nil else { throw ProfileValidationError.conflictingOutbound }
            guard let nodeName, !nodeName.isEmpty else { throw ProfileValidationError.missingNodeName }
        } else if nodeName != nil {
            throw ProfileValidationError.missingNodeName
        }
        if let deviceModel, MacDeviceModel.preset(deviceModel) == nil {
            throw ProfileValidationError.unknownDeviceModel(deviceModel)
        }
        if let url = startURL {
            let scheme = url.scheme?.lowercased() ?? ""
            guard scheme == "http" || scheme == "https" else {
                throw ProfileValidationError.unsupportedStartURLScheme(scheme)
            }
        }
    }

    private static let languageTagPattern = "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"
}

public enum ProfileValidationError: Error, Equatable {
    case emptyName
    case nameTooLong(Int)
    case invalidLanguageTag(String)
    case unknownTimeZone(String)
    case unsupportedStartURLScheme(String)
    /// 同时绑定了独立代理和订阅节点。
    case conflictingOutbound
    /// 绑定了订阅却没指定节点（或指定了节点却没有订阅）。
    case missingNodeName
    case unknownDeviceModel(String)
}
