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
    let original: Profile?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var mode: ProfileMode
    @State private var languageSource: RegionSource
    @State private var languages: String
    @State private var timeZoneSource: RegionSource
    @State private var timeZone: String
    @State private var startURL: String
    @State private var outboundKind: OutboundKind
    @State private var proxyID: UUID?
    @State private var subscriptionID: UUID?
    @State private var nodeName: String?
    @State private var showNodePicker = false
    @State private var deviceModel: String?
    @State private var spi: SPIFeatures
    @State private var notes: String
    @State private var errorText: String?
    @State private var customJSON: String
    @State private var isSaving = false

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

    init(model: ManagerModel, original: Profile?) {
        self.model = model
        self.original = original
        _name = State(initialValue: original?.name ?? "")
        _mode = State(initialValue: original?.mode ?? .persistent)
        _languageSource = State(initialValue: original.map {
            $0.followProxyLanguages ? .proxy : $0.languages.isEmpty ? .system : .custom
        } ?? .system)
        _languages = State(initialValue: original?.languages.joined(separator: ", ") ?? "")
        _timeZoneSource = State(initialValue: original.map {
            $0.followProxyTimeZone ? .proxy : $0.timeZoneIdentifier == nil ? .system : .custom
        } ?? .system)
        _timeZone = State(initialValue: original?.timeZoneIdentifier ?? "")
        _startURL = State(initialValue: original?.startURL?.absoluteString ?? "")
        _customJSON = State(initialValue: original?.customOutboundJSON ?? CustomOutbound.defaultJSON)
        let outbound: OutboundKind
        if original?.customOutboundJSON != nil {
            outbound = .custom
        } else if original?.subscriptionID != nil {
            outbound = .node
        } else {
            outbound = original?.proxyID != nil ? .proxy : .direct
        }
        _outboundKind = State(initialValue: outbound)
        _proxyID = State(initialValue: original?.proxyID)
        _subscriptionID = State(initialValue: original?.subscriptionID)
        _nodeName = State(initialValue: original?.nodeName)
        _deviceModel = State(initialValue: original?.deviceModel)
        _spi = State(initialValue: original?.spi ?? Self.defaultSPI(for: .persistent))
        _notes = State(initialValue: original?.notes ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $name, prompt: Text("例如：美国-工作"))
                    Picker("沙盒模式", selection: $mode) {
                        Text("持久").tag(ProfileMode.persistent)
                        Text("临时").tag(ProfileMode.ephemeral)
                    }
                    .pickerStyle(.segmented)
                    .disabled(original != nil)
                } footer: {
                    Text(DisplayText.modeDetail(mode) + (original == nil ? "。" : "。模式创建后不能更改。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("出站", selection: $outboundKind) {
                        Text("直连").tag(OutboundKind.direct)
                        Text("独立代理").tag(OutboundKind.proxy)
                        Text("订阅节点").tag(OutboundKind.node)
                        Text("高级 JSON").tag(OutboundKind.custom)
                    }
                    .pickerStyle(.segmented)
                    switch outboundKind {
                    case .direct:
                        EmptyView()
                    case .custom:
                        CustomOutboundJSONEditor(json: $customJSON)
                    case .proxy:
                        Picker("代理", selection: $proxyID) {
                            Text("选择代理").tag(UUID?.none)
                            ForEach(model.proxies) { proxy in
                                Text(verbatim: "\(proxy.name) — \(DisplayText.proxyKind(proxy.kind)) \(proxy.host):\(proxy.port)")
                                    .tag(UUID?.some(proxy.id))
                            }
                            if let proxyID, !model.proxies.contains(where: { $0.id == proxyID }) {
                                Text("已被删除的代理（\(proxyID.uuidString.prefix(8))）").tag(UUID?.some(proxyID))
                            }
                        }
                        if model.proxies.isEmpty {
                            Text("还没有独立代理。请先在管理窗口左侧的「代理」中添加 HTTP 或 SOCKS5 代理。")
                                .foregroundStyle(.secondary)
                        }
                    case .node:
                        Picker("订阅", selection: $subscriptionID) {
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
                                        Text(nodeName.map { "「\($0)」已不在订阅里" } ?? "选择节点…")
                                    }
                                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                                }
                            }
                            .disabled(selectedSubscription == nil)
                            .popover(isPresented: $showNodePicker, arrowEdge: .trailing) {
                                NodePickerView(nodes: selectedSubscription?.nodes ?? [], selection: nodeName) { name in
                                    nodeName = name
                                    showNodePicker = false
                                }
                            }
                        }
                    }
                } header: {
                    Text("网络")
                } footer: {
                    Text(outboundFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("模拟机型", selection: $deviceModel) {
                        Text("跟随系统（默认）").tag(String?.none)
                        ForEach(MacDeviceModel.categories, id: \.self) { category in
                            Section(category) {
                                ForEach(MacDeviceModel.presets.filter { $0.category == category }) { preset in
                                    Text(preset.name).tag(String?.some(preset.id))
                                }
                            }
                        }
                    }
                    if let preset = deviceModel.flatMap(MacDeviceModel.preset) {
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
                    regionSourcePicker("语言", selection: $languageSource)
                    if languageSource == .custom {
                        LabeledContent("语言标签") {
                            HStack(spacing: 6) {
                                TextField("语言标签", text: $languages, prompt: Text("例如 en-US, en"))
                                    .labelsHidden()
                                    .autocorrectionDisabled()
                                Menu {
                                    ForEach(Self.languagePresets, id: \.value) { preset in
                                        Button("\(preset.title)  \(preset.value)") { languages = preset.value }
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
                    regionSourcePicker("时区", selection: $timeZoneSource)
                    if timeZoneSource == .custom {
                        LabeledContent("时区标识") {
                            HStack(spacing: 6) {
                                TextField("时区标识", text: $timeZone, prompt: Text("例如 America/Los_Angeles"))
                                    .labelsHidden()
                                    .autocorrectionDisabled()
                                TimeZoneMenu(selection: $timeZone)
                            }
                        }
                    }
                } header: {
                    Text("区域与语言")
                } footer: {
                    Text(regionFooter)
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
                } header: {
                    Text("隐私与指纹保护")
                } footer: {
                    Text("基于系统 WebKit 原生能力实现，不向网页注入任何篡改脚本。高级隐私保护、Safari 专有接口与字体、按语言收窄字体已默认开启。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("其他") {
                    TextField("起始网址", text: $startURL, prompt: Text("https://example.com"))
                        .autocorrectionDisabled()
                    TextField("备注", text: $notes, prompt: Text("可选"), axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 10) {
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let original, model.runState(original.id) != .stopped {
                    Label("这个环境正在运行，修改在下次启动时生效", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isSaving { ProgressView().controlSize(.small) }
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "创建" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 580, height: 600)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .onChange(of: [name, languages, timeZone, startURL]) { errorText = nil }
        .onChange(of: subscriptionID) {
            // 单节点订阅直接选中；多节点订阅保留仍然有效的原选择。
            if let nodes = selectedSubscription?.nodes, nodes.count == 1 {
                nodeName = nodes[0].name
            } else if let nodeName, selectedSubscription?.nodes.contains(where: { $0.name == nodeName }) != true {
                self.nodeName = nil
            }
            errorText = nil
        }
        .onChange(of: outboundKind) {
            errorText = nil
            // 新环境：选了代理或节点就默认跟随代理出口，改回直连就回到跟随系统（自定义的不动）。
            guard original == nil else { return }
            let follow = outboundKind != .direct
            if follow ? languageSource == .system : languageSource == .proxy { languageSource = follow ? .proxy : .system }
            if follow ? timeZoneSource == .system : timeZoneSource == .proxy { timeZoneSource = follow ? .proxy : .system }
        }
        .onChange(of: [languageSource, timeZoneSource]) { errorText = nil }
        .onChange(of: mode) {
            if original == nil { spi = Self.defaultSPI(for: mode) }
        }
    }

    private var selectedSubscription: Subscription? {
        subscriptionID.flatMap(model.subscription)
    }

    private var selectedNode: SubscriptionNode? {
        guard let nodeName else { return nil }
        return selectedSubscription?.nodes.first { $0.name == nodeName }
    }

    private var outboundFooter: String {
        switch outboundKind {
        case .direct: return "不经过代理。"
        case .custom: return "保存前使用 sing-box 校验，校验成功不代表节点可达。配置随环境保存，修改在下次启动时生效；本地入站和默认路由由应用管理。"
        case .proxy: return "在左侧「代理」中统一管理 HTTP / SOCKS5 代理，供多个环境复用。由 WebKit 直接连接，修改后需重启环境。"
        case .node: return "启动时为这个环境单独起一个 sing-box，把节点转成本地 SOCKS5 交给 WebKit；节点连不上时页面加载失败，不会退回直连。节点按名字匹配，订阅刷新后仍然有效。"
        }
    }

    private var regionFooter: String {
        guard languageSource == .proxy || timeZoneSource == .proxy else {
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

    /// 新环境默认开启全部原生隐私保护（WebRTC 和 WebGPU 除外），持久和临时环境一样。
    static func defaultSPI(for mode: ProfileMode) -> SPIFeatures {
        .defaultFeatures
    }

    private func binding(for feature: SPIFeatures) -> Binding<Bool> {
        Binding(
            get: { spi.contains(feature) },
            set: { enabled in
                if enabled { spi.insert(feature) } else { spi.remove(feature) }
            }
        )
    }

    private func save() {
        errorText = nil
        var url: URL?
        let rawURL = startURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawURL.isEmpty {
            // 和浏览窗口的地址栏一样规范化（去掉看不见的字符、没写协议时补上），但起始网址必须是有主机的网页地址，不当成搜索。
            url = AddressInput.webURL(for: rawURL)
            guard url != nil else {
                errorText = "起始网址不合法：\(rawURL)"
                return
            }
        }

        if outboundKind == .direct, languageSource == .proxy || timeZoneSource == .proxy {
            errorText = "「跟随代理」需要选择独立代理或订阅节点。"
            return
        }
        if let message = Self.customRegionError(languageSource: languageSource, languages: languages, timeZoneSource: timeZoneSource, timeZone: timeZone) {
            errorText = message
            return
        }

        var profile = original ?? Profile(name: name, mode: mode)
        profile.customOutboundJSON = nil
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.followProxyLanguages = languageSource == .proxy
        profile.languages = languageSource != .custom ? [] : languages.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        profile.followProxyTimeZone = timeZoneSource == .proxy
        let zone = timeZone.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.timeZoneIdentifier = timeZoneSource != .custom || zone.isEmpty ? nil : zone
        profile.startURL = url
        switch outboundKind {
        case .custom:
            profile.customOutboundJSON = customJSON
            profile.proxyID = nil
            profile.subscriptionID = nil
            profile.nodeName = nil
        case .direct:
            profile.proxyID = nil
            profile.subscriptionID = nil
            profile.nodeName = nil
        case .proxy:
            guard proxyID != nil else {
                errorText = "请选择代理。"
                return
            }
            profile.proxyID = proxyID
            profile.subscriptionID = nil
            profile.nodeName = nil
        case .node:
            guard subscriptionID != nil, nodeName != nil else {
                errorText = "请选择订阅和节点。"
                return
            }
            profile.proxyID = nil
            profile.subscriptionID = subscriptionID
            profile.nodeName = nodeName
        }
        profile.deviceModel = deviceModel
        profile.spi = spi
        profile.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await model.saveValidated(profile, isNew: original == nil)
                dismiss()
            } catch {
                errorText = DisplayText.describe(error)
            }
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
