import SwiftUI
import SafarierCore
import SafarierNetwork

/// 新建 / 编辑环境并选择出站；模式创建后不能改（数据目录跟着 id 走）。
struct ProfileEditorView: View {
    enum OutboundKind: Hashable {
        case direct
        case proxy
        case node
        case custom
    }

    /// 语言 / 时区从哪来。
    enum RegionSource: Hashable {
        /// 启动时按代理出口 IP 的国家自动匹配。
        case proxy
        case system
        case custom
    }

    @ObservedObject var model: ManagerModel
    private let inline: Bool
    @StateObject private var editor: ProfileEditorState
    private var original: Profile? { editor.original }

    @Environment(\.dismiss) private var dismiss
    @State private var showNodePicker = false

    private static let languagePresets: [(title: String, value: String)] = [
        ("英语（美国）", "en-US, en"),
        ("英语（英国）", "en-GB, en"),
        ("日语", "ja-JP, ja"),
        ("韩语", "ko-KR, ko"),
        ("泰语", "th-TH, th"),
        ("简体中文", "zh-CN, zh"),
        ("繁体中文（台湾）", "zh-TW, zh"),
        ("繁体中文（香港）", "zh-HK, zh"),
        ("德语", "de-DE, de"),
        ("法语", "fr-FR, fr"),
        ("西班牙语", "es-ES, es"),
    ]

    init(model: ManagerModel, original: Profile?, inline: Bool = false) {
        self.model = model
        self.inline = inline
        if inline, let original {
            _editor = StateObject(wrappedValue: model.editor(for: original))
        } else {
            _editor = StateObject(wrappedValue: ProfileEditorState(original: original))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if inline, let original {
                    Section {
                        ProfileDetailHeader(model: model, profile: original, editor: editor)
                    }
                }
                if !inline {
                    Section {
                        TextField("名称", text: $editor.values.name, prompt: Text("例如：美国-工作"))
                        Picker("沙盒模式", selection: $editor.values.mode) {
                            Text("持久").tag(ProfileMode.persistent)
                            Text("临时").tag(ProfileMode.ephemeral)
                        }
                        .pickerStyle(.segmented)
                        .disabled(original != nil)
                    } footer: {
                        Text(DisplayText.modeDetail(editor.values.mode) + (original == nil ? "。" : "。模式创建后不能更改。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if inline {
                        outboundPicker.pickerStyle(.menu)
                    } else {
                        outboundPicker.pickerStyle(.segmented)
                    }
                    switch editor.values.outboundKind {
                    case .direct:
                        EmptyView()
                    case .custom:
                        CustomOutboundJSONEditor(json: $editor.values.customJSON)
                    case .proxy:
                        Picker("代理", selection: $editor.values.proxyID) {
                            Text("选择代理").tag(UUID?.none)
                            ForEach(model.proxies) { proxy in
                                Text(verbatim: "\(proxy.name) — \(DisplayText.proxyKind(proxy.kind)) \(proxy.host):\(proxy.port)")
                                    .tag(UUID?.some(proxy.id))
                            }
                            if let proxyID = editor.values.proxyID, !model.proxies.contains(where: { $0.id == proxyID }) {
                                Text("已被删除的代理（\(proxyID.uuidString.prefix(8))）").tag(UUID?.some(proxyID))
                            }
                        }
                        if model.proxies.isEmpty {
                            Text("还没有独立代理。请先在管理窗口左侧的「代理」中添加 HTTP 或 SOCKS5 代理。")
                                .foregroundStyle(.secondary)
                        }
                    case .node:
                        Picker("订阅", selection: $editor.values.subscriptionID) {
                            Text("选择订阅").tag(UUID?.none)
                            ForEach(model.subscriptions) { subscription in
                                Text(verbatim: "\(subscription.name)（\(subscription.nodes.count) 个节点）").tag(UUID?.some(subscription.id))
                            }
                        }
                        LabeledContent("节点") {
                            Button { showNodePicker = true } label: {
                                HStack(spacing: 6) {
                                    if let node = selectedNode {
                                        Text(node.name).lineLimit(1)
                                        ProtocolBadge(type: node.type)
                                    } else {
                                        Text(editor.values.nodeName.map { "「\($0)」已不在订阅里" } ?? "选择节点…")
                                    }
                                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                                }
                            }
                            .disabled(selectedSubscription == nil)
                            .popover(isPresented: $showNodePicker, arrowEdge: .trailing) {
                                NodePickerView(nodes: selectedSubscription?.nodes ?? [], selection: editor.values.nodeName) { name in
                                    editor.values.nodeName = name
                                    showNodePicker = false
                                }
                            }
                        }
                    }
                } header: {
                    Text("网络")
                } footer: {
                    if !inline || editor.values.outboundKind == .custom {
                        Text(outboundFooter)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    regionSourcePicker("语言", selection: $editor.values.languageSource)
                    if editor.values.languageSource == .custom {
                        LabeledContent("语言标签") {
                            HStack(spacing: 6) {
                                TextField("语言标签", text: $editor.values.languages, prompt: Text("例如 en-US, en"))
                                    .labelsHidden()
                                    .autocorrectionDisabled()
                                Menu {
                                    ForEach(Self.languagePresets, id: \.value) { preset in
                                        Button("\(preset.title)  \(preset.value)") { editor.values.languages = preset.value }
                                    }
                                } label: {
                                    Image(systemName: "character.bubble")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("常用语言")
                            }
                        }
                    }
                    regionSourcePicker("时区", selection: $editor.values.timeZoneSource)
                    if editor.values.timeZoneSource == .custom {
                        LabeledContent("时区标识") {
                            HStack(spacing: 6) {
                                TextField("时区标识", text: $editor.values.timeZone, prompt: Text("例如 America/Los_Angeles"))
                                    .labelsHidden()
                                    .autocorrectionDisabled()
                                TimeZoneMenu(selection: $editor.values.timeZone)
                            }
                        }
                    }
                } header: {
                    Text("区域与语言")
                } footer: {
                    if !inline {
                        Text(regionFooter)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker(inline ? "机型" : "模拟机型", selection: $editor.values.deviceModel) {
                        Text("跟随系统（默认）").tag(String?.none)
                        ForEach(MacDeviceModel.categories, id: \.self) { category in
                            Section(category) {
                                ForEach(MacDeviceModel.presets.filter { $0.category == category }) { preset in
                                    Text(preset.name).tag(String?.some(preset.id))
                                }
                            }
                        }
                    }
                    if let preset = editor.values.deviceModel.flatMap(MacDeviceModel.preset) {
                        LabeledContent("芯片规格", value: DisplayText.hardware(preset))
                        LabeledContent("屏幕", value: DisplayText.screen(preset))
                        LabeledContent("网页看到的", value: DisplayText.webVisible(preset))
                        LabeledContent("推荐视口", value: DisplayText.viewport(preset))
                    }
                } header: {
                    Text("机型模拟")
                } footer: {
                    Text(DisplayText.deviceModelNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(SPIFeatures.tokens, id: \.name) { token in
                        let text = DisplayText.spi(token.feature)
                        Toggle(isOn: binding(for: token.feature)) {
                            Text(text.title)
                            Text(text.detail)
                        }
                    }
                    Toggle(isOn: $editor.values.hideApplePayCardStatus) {
                        Text("隐藏 Apple Pay 银行卡状态")
                        Text("仅在 Safari 专有接口开启时生效。关闭银行卡状态查询以改善检测兼容性；不提供 Apple Pay 支付权限。修改后重启环境生效。")
                    }
                    .disabled(!editor.values.spi.contains(.safariAPIs))
                } header: {
                    Text("隐私与指纹保护")
                } footer: {
                    Text("基于系统 WebKit 原生能力实现，不向网页注入任何篡改脚本。高级隐私保护、Safari 专有接口与字体、按语言收窄字体已默认开启；配置代理或节点时默认一并关闭 WebRTC，防止 STUN 泄露真实 IP。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if inline, let original {
                    ProfileMetadataSections(model: model, profile: original)
                }

                Section("其他") {
                    TextField("起始网址", text: $editor.values.startURL, prompt: Text("https://example.com"))
                        .autocorrectionDisabled()
                    TextField("备注", text: $editor.values.notes, prompt: Text("可选"), axis: .vertical)
                        .lineLimit(2...4)
                    if inline, let original {
                        LabeledContent("创建时间", value: original.createdAt.formatted(date: .long, time: .shortened))
                        LabeledContent("环境 ID") {
                            Text(original.id.uuidString).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 10) {
                if let errorText = editor.errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let original, model.runState(original.id) != .stopped {
                    Label("这个环境正在运行，修改在下次启动时生效", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if editor.isSaving { ProgressView().controlSize(.small) }
                if inline, let original {
                    if editor.hasChanges { Text("未保存的修改").foregroundStyle(.secondary) }
                    Button("还原") { editor.reset(to: model.profile(original.id) ?? original) }
                        .disabled(!editor.hasChanges && editor.errorText == nil)
                } else {
                    Button("取消", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(original == nil ? "创建" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editor.values.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (inline && !editor.hasChanges))
            }
            .padding(16)
        }
        .frame(width: inline ? nil : 580, height: inline ? nil : 600)
        .disabled(editor.isSaving)
        .interactiveDismissDisabled(editor.isSaving)
        .toolbar {
            if inline, let original {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.duplicate(original) } label: {
                        Label("复制环境", systemImage: "plus.square.on.square")
                    }
                    .help("复制环境（不复制网站数据）")
                    .disabled(editor.hasChanges || editor.isSaving)
                    Button { model.launch(original) } label: {
                        Label("启动浏览器", systemImage: "play.fill")
                    }
                    .help(editor.hasChanges ? "请先保存或还原修改" : "启动浏览器")
                    .disabled(model.runState(original.id) != .stopped || editor.hasChanges || editor.isSaving)
                }
            }
        }
        .onChange(of: [editor.values.name, editor.values.languages, editor.values.timeZone, editor.values.startURL]) { editor.errorText = nil }
        .onChange(of: editor.values.subscriptionID) {
            // 单节点订阅直接选中；多节点订阅保留仍然有效的原选择。
            if let nodes = selectedSubscription?.nodes, nodes.count == 1 {
                editor.values.nodeName = nodes[0].name
            } else if let nodeName = editor.values.nodeName, selectedSubscription?.nodes.contains(where: { $0.name == nodeName }) != true {
                editor.values.nodeName = nil
            }
            editor.errorText = nil
        }
        .onChange(of: editor.values.outboundKind) {
            editor.errorText = nil
            let follow = editor.values.outboundKind != .direct
            // 未手动改过 WebRTC 开关时：新环境或原本直连的环境切到代理/节点/自定义出站自动开启「关闭 WebRTC」，新环境切回直连则恢复默认。
            if !editor.userToggledWebRTC, original == nil || original?.hasOutboundProxy == false {
                if follow {
                    editor.values.spi.insert(.disableWebRTC)
                } else if original == nil {
                    editor.values.spi.remove(.disableWebRTC)
                }
            }
            // 新环境：选了代理或节点就默认跟随代理出口，改回直连就回到跟随系统（自定义的不动）。
            guard original == nil else { return }
            if follow ? editor.values.languageSource == .system : editor.values.languageSource == .proxy { editor.values.languageSource = follow ? .proxy : .system }
            if follow ? editor.values.timeZoneSource == .system : editor.values.timeZoneSource == .proxy { editor.values.timeZoneSource = follow ? .proxy : .system }
        }
        .onChange(of: [editor.values.languageSource, editor.values.timeZoneSource]) { editor.errorText = nil }
        .onChange(of: editor.values.mode) {
            if original == nil { editor.values.spi = Self.defaultSPI(for: editor.values.mode, hasProxy: editor.values.outboundKind != .direct) }
        }
    }

    private var outboundPicker: some View {
        Picker("出站", selection: $editor.values.outboundKind) {
            Text("直连").tag(OutboundKind.direct)
            Text("独立代理").tag(OutboundKind.proxy)
            Text("订阅节点").tag(OutboundKind.node)
            Text("高级 JSON").tag(OutboundKind.custom)
        }
    }

    private var selectedSubscription: Subscription? {
        editor.values.subscriptionID.flatMap(model.subscription)
    }

    private var selectedNode: SubscriptionNode? {
        guard let nodeName = editor.values.nodeName else { return nil }
        return selectedSubscription?.nodes.first { $0.name == nodeName }
    }

    private var outboundFooter: String {
        switch editor.values.outboundKind {
        case .direct: return "不经过代理。"
        case .custom: return "保存前使用 sing-box 校验，校验成功不代表节点可达。配置随环境保存，修改在下次启动时生效；本地入站和默认路由由应用管理。"
        case .proxy: return "在左侧「代理」中统一管理 HTTP / SOCKS5 代理，供多个环境复用。由 WebKit 直接连接，修改后需重启环境。"
        case .node: return "启动时为这个环境单独起一个 sing-box，把节点转成本地 SOCKS5 交给 WebKit；节点连不上时页面加载失败，不会退回直连。节点按名字匹配，订阅刷新后仍然有效。"
        }
    }

    private var regionFooter: String {
        guard editor.values.languageSource == .proxy || editor.values.timeZoneSource == .proxy else {
            return "跟随系统时使用宿主机的语言和时区。"
        }
        return "跟随代理：每次启动经代理查询出口 IP 所在国家，自动设置语言和时区（时区跟随时一并开启引擎层时区同步）；查询失败时按节点名称推断，仍无法判断则跟随系统。"
    }

    /// 选了「自定义」却没填：报错，不悄悄存成「跟随系统」。
    static func customRegionError(languageSource: RegionSource, languages: String, timeZoneSource: RegionSource, timeZone: String) -> String? {
        if languageSource == .custom, !languages.split(separator: ",").contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "请填写语言标签（例如 en-US, en），或改选「跟随系统」。"
        }
        if timeZoneSource == .custom, timeZone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写时区（例如 America/Los_Angeles），或改选「跟随系统」。"
        }
        return nil
    }

    private func regionSourcePicker(_ title: String, selection: Binding<RegionSource>) -> some View {
        Picker(title, selection: selection) {
            Text(DisplayText.followProxy).tag(RegionSource.proxy)
            Text("跟随系统").tag(RegionSource.system)
            Text("自定义").tag(RegionSource.custom)
        }
    }

    /// 新环境默认开启全部原生隐私保护（直连时 WebRTC 和 WebGPU 除外，配置代理时一并开启关闭 WebRTC），持久和临时环境一样。
    static func defaultSPI(for mode: ProfileMode, hasProxy: Bool = false) -> SPIFeatures {
        SPIFeatures.defaultFeatures(hasProxy: hasProxy)
    }

    private func binding(for feature: SPIFeatures) -> Binding<Bool> {
        Binding(
            get: { editor.values.spi.contains(feature) },
            set: { enabled in
                if feature == .disableWebRTC { editor.userToggledWebRTC = true }
                if enabled { editor.values.spi.insert(feature) } else { editor.values.spi.remove(feature) }
            }
        )
    }

    private func save() {
        Task { @MainActor in
            if await editor.save(using: model, selectSavedProfile: !inline), !inline { dismiss() }
        }
    }

}

/// 常用时区 + 按地区分组的完整列表。
struct TimeZoneMenu: View {
    @Binding var selection: String

    private static let common = [
        "America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York",
        "Europe/London", "Europe/Paris", "Europe/Berlin",
        "Asia/Tokyo", "Asia/Seoul", "Asia/Bangkok", "Asia/Singapore", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Shanghai",
        "Australia/Sydney",
    ]

    private static let regions: [(name: String, zones: [String])] = Dictionary(
        grouping: TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") },
        by: { String($0.prefix { $0 != "/" }) }
    )
    .map { (name: $0.key, zones: $0.value.sorted()) }
    .sorted { $0.name < $1.name }

    var body: some View {
        Menu {
            Section("常用") {
                ForEach(Self.common, id: \.self) { zone in
                    Button(DisplayText.timeZone(zone)) { selection = zone }
                }
            }
            Divider()
            ForEach(Self.regions, id: \.name) { region in
                Menu(region.name) {
                    ForEach(region.zones, id: \.self) { zone in
                        Button(zone) { selection = zone }
                    }
                }
            }
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择时区")
    }
}

/// 订阅节点选择：按名称或服务器搜索。
struct NodePickerView: View {
    let nodes: [SubscriptionNode]
    let selection: String?
    let onSelect: (String) -> Void

    @State private var query = ""

    private var filtered: [SubscriptionNode] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nodes }
        return nodes.filter {
            $0.name.localizedCaseInsensitiveContains(text) || "\($0.server):\($0.serverPort)".contains(text)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索名称或服务器", text: $query)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            List(filtered) { node in
                Button { onSelect(node.name) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .opacity(node.name == selection ? 1 : 0)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name).lineLimit(1)
                            Text(verbatim: "\(node.server):\(node.serverPort)")
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        ProtocolBadge(type: node.type)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            Divider()
            Text(query.isEmpty ? "共 \(nodes.count) 个节点" : "\(filtered.count) / \(nodes.count) 个节点")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .frame(width: 400, height: 440)
    }
}
