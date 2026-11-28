import SwiftUI
import SafarierCore
import SafarierNetwork

/// 新建与详情页共用的表单值；未完成或无效的输入只留在内存中。
struct ProfileEditorValues: Equatable {
    var name: String
    var mode: ProfileMode
    var languageSource: ProfileEditorView.RegionSource
    var languages: String
    var timeZoneSource: ProfileEditorView.RegionSource
    var timeZone: String
    var startupTabs: [StartupTabDraft]
    var outboundKind: ProfileEditorView.OutboundKind
    var proxyID: UUID?
    var subscriptionID: UUID?
    var nodeName: String?
    var deviceModel: String?
    var spi: SPIFeatures
    var hideApplePayCardStatus: Bool
    var notes: String
    var customJSON: String
    var bypassSystemProxy: Bool

    init(original: Profile?) {
        name = original?.name ?? ""
        mode = original?.mode ?? .persistent
        languageSource = original.map {
            $0.followProxyLanguages ? .proxy : $0.languages.isEmpty ? .system : .custom
        } ?? .system
        languages = original?.languages.joined(separator: ", ") ?? ""
        timeZoneSource = original.map {
            $0.followProxyTimeZone ? .proxy : $0.timeZoneIdentifier == nil ? .system : .custom
        } ?? .system
        timeZone = original?.timeZoneIdentifier ?? ""
        startupTabs = original?.startupTabs.map(StartupTabDraft.init) ?? []
        customJSON = original?.customOutboundJSON ?? CustomOutbound.defaultJSON
        switch original?.outbound {
        case .customSingbox:
            outboundKind = .custom
            bypassSystemProxy = false
        case .subscriptionNode:
            outboundKind = .node
            bypassSystemProxy = false
        case .proxy:
            outboundKind = .proxy
            bypassSystemProxy = false
        case .direct(let bypass):
            outboundKind = .direct
            bypassSystemProxy = bypass
        case nil:
            outboundKind = .direct
            bypassSystemProxy = false
        }
        proxyID = original?.proxyID
        subscriptionID = original?.subscriptionID
        nodeName = original?.nodeName
        deviceModel = original?.deviceModel
        spi = original?.spi ?? ProfileEditorView.defaultSPI(for: .persistent)
        hideApplePayCardStatus = original?.hideApplePayCardStatus ?? true
        notes = original?.notes ?? ""
    }

    func profile(original: Profile?) throws -> Profile {
        let tabs = try startupTabs.enumerated().map { try $0.element.validatedTab(at: $0.offset) }

        if outboundKind == .direct, languageSource == .proxy || timeZoneSource == .proxy {
            throw ProfileEditorError.invalid(L10n.text("「跟随代理」需要选择独立代理或订阅节点。"))
        }
        if let message = ProfileEditorView.customRegionError(languageSource: languageSource, languages: languages, timeZoneSource: timeZoneSource, timeZone: timeZone) {
            throw ProfileEditorError.invalid(message)
        }

        var profile = original ?? Profile(name: name, mode: mode)
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.followProxyLanguages = languageSource == .proxy
        profile.languages = languageSource != .custom ? [] : languages.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        profile.followProxyTimeZone = timeZoneSource == .proxy
        let zone = timeZone.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.timeZoneIdentifier = timeZoneSource != .custom || zone.isEmpty ? nil : zone
        profile.startupTabs = tabs
        switch outboundKind {
        case .custom:
            profile.setOutbound(.customSingbox(customJSON))
        case .direct:
            profile.setOutbound(.direct(bypassSystemProxy: bypassSystemProxy))
        case .proxy:
            guard let proxyID else {
                throw ProfileEditorError.invalid(L10n.text("请选择代理。"))
            }
            profile.setOutbound(.proxy(proxyID))
        case .node:
            guard let subscriptionID, let nodeName else {
                throw ProfileEditorError.invalid(L10n.text("请选择订阅和节点。"))
            }
            profile.setOutbound(.subscriptionNode(subscriptionID: subscriptionID, nodeName: nodeName))
        }
        profile.deviceModel = deviceModel
        profile.spi = spi
        profile.hideApplePayCardStatus = hideApplePayCardStatus
        profile.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        try profile.validate()
        return profile
    }
}

enum ProfileEditorError: LocalizedError {
    case invalid(String)
    case changedExternally

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .changedExternally: return L10n.text("环境已在其他位置修改，请先还原为最新设置，再重新编辑。")
        }
    }
}

/// 由管理器按环境 ID 保留，切换详情页不会丢失草稿；新建表单独立持有。
@MainActor
final class ProfileEditorState: ObservableObject {
    @Published var values: ProfileEditorValues
    @Published private(set) var original: Profile?
    @Published var errorText: String?
    @Published private(set) var isSaving = false
    var userToggledWebRTC = false

    init(original: Profile?) {
        self.original = original
        values = ProfileEditorValues(original: original)
    }

    var hasChanges: Bool {
        guard let original else { return true }
        return (try? values.profile(original: original)) != original
    }

    func receive(_ profile: Profile) {
        guard !isSaving, !hasChanges, profile != original else { return }
        reset(to: profile)
    }

    func reset(to profile: Profile) {
        guard !isSaving else { return }
        accept(profile)
    }

    private func accept(_ profile: Profile) {
        original = profile
        values = ProfileEditorValues(original: profile)
        userToggledWebRTC = false
        errorText = nil
    }

    @discardableResult
    func save(using model: ManagerModel, selectSavedProfile: Bool,
              executableURL: URL = SingboxProcessManager.defaultExecutableURL) async -> Bool {
        guard !isSaving else { return false }
        errorText = nil
        isSaving = true
        defer { isSaving = false }
        do {
            let profile = try values.profile(original: original)
            try await model.saveValidated(profile, isNew: original == nil, executableURL: executableURL,
                                          expectedProfile: original, selectSavedProfile: selectSavedProfile)
            accept(model.profile(profile.id) ?? profile)
            return true
        } catch ProfileEditorError.changedExternally {
            model.reload()
            errorText = ProfileEditorError.changedExternally.localizedDescription
            return false
        } catch {
            errorText = DisplayText.describe(error)
            return false
        }
    }
}
