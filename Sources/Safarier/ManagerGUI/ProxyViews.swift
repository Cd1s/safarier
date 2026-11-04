import SwiftUI
import SafarierCore
import SafarierNetwork

enum ProxyManagementError: Error, LocalizedError {
    case emptyName
    case emptyUsername
    case missingPassword
    case invalidPort
    case inUse([String])
    case usedAsUpstream([String])
    case credentialRollbackFailed

    var errorDescription: String? {
        switch self {
        case .emptyName: return "请填写代理名称。"
        case .emptyUsername: return "开启认证后请填写用户名。"
        case .missingPassword: return "请填写认证密码。编辑已有代理时留空可保留原密码。"
        case .invalidPort: return "端口必须是 1–65535 之间的整数。"
        case .inUse(let names): return "这些环境仍在使用此代理：\(names.joined(separator: "、"))。请先在环境中更换出站。"
        case .usedAsUpstream(let names): return "这些代理仍将它用作前置：\(names.joined(separator: "、"))。请先更换前置连接。"
        case .credentialRollbackFailed: return "配置保存失败，且原密码未能恢复。请重新设置该代理的认证密码。"
        }
    }
}

struct ProxyEditorView: View {
    enum UpstreamKind: String, CaseIterable {
        case proxy = "已保存代理"
        case node = "订阅节点"
        case custom = "自定义"
    }

    @ObservedObject var model: ManagerModel
    let original: ProxySettings?
    var onSaved: ((ProxySettings) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: ProxyKind
    @State private var host: String
    @State private var port: String
    @State private var authenticated: Bool
    @State private var username: String
    @State private var password = ""
    @State private var errorText: String?
    @State private var upstreamEnabled: Bool
    @State private var upstreamKind: UpstreamKind
    @State private var upstreamProxyID: UUID?
    @State private var subscriptionID: UUID?
    @State private var nodeName: String?
    @State private var customJSON: String
    @State private var showNodes = false
    @State private var showNewProxy = false
    @State private var isSaving = false

    init(model: ManagerModel, original: ProxySettings?, onSaved: ((ProxySettings) -> Void)? = nil) {
        self.model = model
        self.original = original
        self.onSaved = onSaved
        _name = State(initialValue: original?.name ?? "")
        _kind = State(initialValue: original?.kind ?? .socks5)
        _host = State(initialValue: original?.host ?? "127.0.0.1")
        _port = State(initialValue: original.map { String($0.port) } ?? "1080")
        _authenticated = State(initialValue: original?.username != nil)
        _username = State(initialValue: original?.username ?? "")
        _upstreamEnabled = State(initialValue: original?.upstream != nil)
        var kind: UpstreamKind = .proxy
        var proxyID: UUID?
        var subscriptionID: UUID?
        var nodeName: String?
        var json = CustomOutbound.defaultJSON
        switch original?.upstream {
        case .proxy(let id): kind = .proxy; proxyID = id
        case .node(let id, let name): kind = .node; subscriptionID = id; nodeName = name
        case .custom(let value): kind = .custom; json = value
        case nil: break
        }
        _upstreamKind = State(initialValue: kind)
        _upstreamProxyID = State(initialValue: proxyID)
        _subscriptionID = State(initialValue: subscriptionID)
        _nodeName = State(initialValue: nodeName)
        _customJSON = State(initialValue: json)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("出口代理") {
                    TextField("名称", text: $name, prompt: Text("例如：本地代理"))
                    Picker("协议", selection: $kind) {
                        Text("SOCKS5").tag(ProxyKind.socks5)
                        Text("HTTP CONNECT").tag(ProxyKind.httpConnect)
                    }
                    TextField("服务器", text: $host, prompt: Text("主机名或 IP 地址"))
                        .autocorrectionDisabled()
                    TextField("端口", text: $port)
                        .autocorrectionDisabled()
                }
                Section {
                    Toggle("用户名和密码认证", isOn: $authenticated)
                    if authenticated {
                        TextField("用户名", text: $username)
                            .autocorrectionDisabled()
                        SecureField("密码", text: $password, prompt: Text(original?.username == nil ? "请输入密码" : "留空保留原密码"))
                    }
                } footer: {
                    Text("密码保存在 macOS 钥匙串中。保存后可供多个环境选择；已运行的环境需要重启后才会使用新设置。")
                }
                upstreamSection.disabled(onSaved != nil)
            }
            .formStyle(.grouped)
            .disabled(isSaving)
            VStack(alignment: .leading, spacing: 4) {
                Text("连接路径").font(.caption).foregroundStyle(.secondary)
                Text(connectionPath).textSelection(.enabled)
                if original != nil {
                    Text("重启环境后生效。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            HStack {
                if let errorText { Text(errorText).foregroundStyle(.red).lineLimit(3) }
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: upstreamEnabled ? (upstreamKind == .custom ? 760 : 650) : 540)
        .onChange(of: [name, host, port, username, password]) { errorText = nil }
        .onChange(of: subscriptionID) { nodeName = nil; errorText = nil }
        .onChange(of: upstreamEnabled) { errorText = nil }
        .onChange(of: upstreamKind) { errorText = nil }
        .onChange(of: upstreamProxyID) { errorText = nil }
        .onChange(of: nodeName) { errorText = nil }
        .onChange(of: customJSON) { errorText = nil }
        .sheet(isPresented: $showNewProxy) {
            ProxyEditorView(model: model, original: nil) { saved in
                upstreamProxyID = saved.id
            }
        }
    }

    private var availableProxies: [ProxySettings] {
        model.proxies.filter { $0.id != original?.id && $0.upstream == nil }
    }

    private var selectedSubscription: Subscription? { subscriptionID.flatMap(model.subscription) }

    private var connectionPath: String {
        let exit = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "当前出口代理" : name
        guard upstreamEnabled else { return "本机 → \(exit) → 网站" }
        let entry: String
        switch upstreamKind {
        case .proxy: entry = upstreamProxyID.flatMap(model.proxy)?.name ?? "选择前置代理"
        case .node: entry = nodeName ?? "选择前置节点"
        case .custom: entry = "自定义前置"
        }
        return "本机 → \(entry) → \(exit) → 网站"
    }

    /// 已被其它代理用作前置时不能再加前置（只支持两跳），保存前就禁用选择。
    private var downstreamExits: [ProxySettings] {
        original.map(model.proxies(using:)) ?? []
    }

    private var upstreamSection: some View {
        Section {
            Toggle("前置连接", isOn: $upstreamEnabled)
                .disabled(!downstreamExits.isEmpty && !upstreamEnabled)
            if !downstreamExits.isEmpty {
                Text("此代理已被「\(downstreamExits.map(\.name).joined(separator: "、"))」用作前置，不能再添加前置。")
                    .foregroundStyle(.secondary)
            }
            if upstreamEnabled {
                Picker("来源", selection: $upstreamKind) {
                    ForEach(UpstreamKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                upstreamOptions
            }
        } footer: {
            if upstreamEnabled {
                Text("先连接前置，再连接当前代理。")
            }
        }
    }

    @ViewBuilder
    private var upstreamOptions: some View {
        switch upstreamKind {
        case .proxy:
            Picker("前置代理", selection: $upstreamProxyID) {
                Text("选择代理").tag(UUID?.none)
                ForEach(availableProxies) { proxy in
                    Text(proxy.name).tag(UUID?.some(proxy.id))
                }
                if let id = upstreamProxyID, !availableProxies.contains(where: { $0.id == id }) {
                    Text("前置代理已删除或不可用").tag(UUID?.some(id))
                }
            }
            Button("新增代理…") { showNewProxy = true }
        case .node:
            Picker("订阅", selection: $subscriptionID) {
                Text("选择订阅").tag(UUID?.none)
                ForEach(model.subscriptions) { Text($0.name).tag(UUID?.some($0.id)) }
                if let id = subscriptionID, model.subscription(id) == nil {
                    Text("订阅已删除").tag(UUID?.some(id))
                }
            }
            LabeledContent("前置节点") {
                Button {
                    showNodes = true
                } label: {
                    Text(nodeName ?? "选择节点…").lineLimit(1)
                }
                .disabled(selectedSubscription == nil)
                .popover(isPresented: $showNodes) {
                    NodePickerView(nodes: selectedSubscription?.nodes ?? [], selection: nodeName) { name in
                        nodeName = name
                        showNodes = false
                    }
                }
            }
            if let nodeName, selectedSubscription?.nodes.contains(where: { $0.name == nodeName }) != true {
                Text("此节点已不在订阅中，请重新选择。").foregroundStyle(.orange)
            }
        case .custom:
            CustomOutboundJSONEditor(json: $customJSON)
        }
    }

    private func save() {
        do {
            guard let port = Int(port), (1...65535).contains(port) else { throw ProxyManagementError.invalidPort }
            var proxy = original ?? ProxySettings(name: name, kind: kind, host: host, port: port)
            proxy.name = name
            proxy.kind = kind
            proxy.host = host
            proxy.port = port
            proxy.username = authenticated ? username : nil
            if !upstreamEnabled {
                proxy.upstream = nil
            } else {
                switch upstreamKind {
                case .proxy:
                    guard let id = upstreamProxyID else { throw ProxyChainError.missingProxy }
                    proxy.upstream = .proxy(id)
                case .node:
                    guard let id = subscriptionID else { throw ProxyChainError.missingSubscription }
                    guard let nodeName else { throw ProxyChainError.missingNode }
                    proxy.upstream = .node(subscriptionID: id, name: nodeName)
                case .custom: proxy.upstream = .custom(customJSON)
                }
            }
            let draft = proxy
            let password = password.isEmpty ? nil : password
            isSaving = true
            Task { @MainActor in
                defer { isSaving = false }
                do {
                    try await model.saveProxyValidated(draft, password: password, isNew: original == nil)
                    onSaved?(model.proxy(draft.id) ?? draft)
                    dismiss()
                } catch { errorText = DisplayText.describe(error) }
            }
        } catch { errorText = DisplayText.describe(error) }
    }
}

struct ProxyDetailView: View {
    @ObservedObject var model: ManagerModel
    let proxy: ProxySettings

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(proxy.name, systemImage: "network").font(.title2.weight(.semibold))
                    Spacer()
                    Button("编辑…") { model.sheet = .editProxy(proxy) }
                    Button("删除…", role: .destructive) { model.confirmation = .deleteProxy(proxy) }
                        .disabled(!model.profiles(using: proxy).isEmpty || !model.proxies(using: proxy).isEmpty)
                }
                LabeledContent("协议", value: DisplayText.proxyKind(proxy.kind))
                LabeledContent("服务器", value: proxy.host)
                LabeledContent("端口", value: String(proxy.port))
                LabeledContent("认证", value: proxy.username.map { "用户名：\($0) · 密码保存在钥匙串" } ?? "无认证")
                if proxy.upstream != nil {
                    LabeledContent("连接路径", value: model.connectionPath(proxy))
                }
            } footer: {
                Text(proxy.upstream == nil ? "无前置时由 WebKit 直接连接。修改在关联环境下次启动时生效。" : "通过前置连接当前出口，任一跳失败都会阻止访问。修改在关联环境下次启动时生效。")
            }
            Section {
                HStack {
                    Text("连通性")
                    Spacer()
                    if model.proxyTests[proxy.id] == .running {
                        ProgressView().controlSize(.small)
                        Button("取消测试") { model.cancelProxyTest(proxy.id) }
                    } else {
                        Button("测试连接") { model.testProxy(proxy) }
                    }
                }
                switch model.proxyTests[proxy.id] {
                case .running:
                    Text(proxy.upstream == nil ? "正在通过此代理请求 HTTPS…" : "正在通过完整两跳链路请求 HTTPS…").foregroundStyle(.secondary)
                case .success(let result):
                    Label("HTTPS 连接成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    LabeledContent("出口 IP", value: result.exitIP)
                    LabeledContent("请求耗时", value: "\(Int(result.duration * 1000)) ms")
                    LabeledContent("测试时间", value: result.testedAt.formatted(date: .omitted, time: .standard))
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                case nil:
                    Text("尚未测试").foregroundStyle(.secondary)
                }
            } footer: {
                Text("通过所选代理访问 Cloudflare HTTPS，最多等待 \(Int(ProxyConnectionTester.timeout)) 秒，不回退直连。结果仅代表此测试站点，不修改代理配置。")
            }
            Section("使用此代理的环境") {
                if model.profiles(using: proxy).isEmpty {
                    Text("尚未关联环境。在新建或编辑环境的「独立代理」中选择此代理。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.profiles(using: proxy)) { profile in
                    Button(profile.name) { model.selection = .profile(profile.id) }
                }
            }
            if !model.proxies(using: proxy).isEmpty {
                Section("将此代理用作前置的代理") {
                    ForEach(model.proxies(using: proxy)) { exit in
                        Button(exit.name) { model.selection = .proxy(exit.id) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(proxy.name)
    }
}

struct ProxyRow: View {
    let proxy: ProxySettings
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(proxy.name).fontWeight(.medium)
                Text(verbatim: "\(DisplayText.proxyKind(proxy.kind)) · \(proxy.host):\(proxy.port)")
                    .font(.caption).foregroundStyle(.secondary)
                if proxy.upstream != nil { Text("已配置前置连接").font(.caption).foregroundStyle(.secondary) }
            }.lineLimit(1)
        } icon: { Image(systemName: "network").foregroundStyle(.blue) }
    }
}
