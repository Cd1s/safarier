import SwiftUI
import SafarierCore
import SafarierNetwork

enum ProxyManagementError: Error, LocalizedError {
    case emptyName
    case emptyUsername
    case missingPassword
    case invalidPort
    case inUse([String])
    case credentialRollbackFailed

    var errorDescription: String? {
        switch self {
        case .emptyName: return "请填写代理名称。"
        case .emptyUsername: return "开启认证后请填写用户名。"
        case .missingPassword: return "请填写认证密码。编辑已有代理时留空可保留原密码。"
        case .invalidPort: return "端口必须是 1–65535 之间的整数。"
        case .inUse(let names): return "这些环境仍在使用此代理：\(names.joined(separator: "、"))。请先在环境中更换出站。"
        case .credentialRollbackFailed: return "配置保存失败，且原密码未能恢复。请重新设置该代理的认证密码。"
        }
    }
}

struct ProxyEditorView: View {
    @ObservedObject var model: ManagerModel
    let original: ProxySettings?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: ProxyKind
    @State private var host: String
    @State private var port: String
    @State private var authenticated: Bool
    @State private var username: String
    @State private var password = ""
    @State private var errorText: String?

    init(model: ManagerModel, original: ProxySettings?) {
        self.model = model
        self.original = original
        _name = State(initialValue: original?.name ?? "")
        _kind = State(initialValue: original?.kind ?? .socks5)
        _host = State(initialValue: original?.host ?? "127.0.0.1")
        _port = State(initialValue: original.map { String($0.port) } ?? "1080")
        _authenticated = State(initialValue: original?.username != nil)
        _username = State(initialValue: original?.username ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(original == nil ? "添加代理" : "编辑代理") {
                    TextField("名称", text: $name, prompt: Text("例如：本地代理"))
                    Picker("协议", selection: $kind) {
                        Text("SOCKS5").tag(ProxyKind.socks5)
                        Text("HTTP CONNECT").tag(ProxyKind.httpConnect)
                    }
                    TextField("服务器", text: $host, prompt: Text("主机名或 IP 地址"))
                    TextField("端口", text: $port)
                }
                Section {
                    Toggle("用户名和密码认证", isOn: $authenticated)
                    if authenticated {
                        TextField("用户名", text: $username)
                        SecureField("密码", text: $password, prompt: Text(original?.username == nil ? "请输入密码" : "留空保留原密码"))
                    }
                } footer: {
                    Text("密码保存在 macOS 钥匙串中。保存后可供多个环境选择；已运行的环境需要重启后才会使用新设置。")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let errorText { Text(errorText).foregroundStyle(.red).lineLimit(3) }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 500, height: 460)
        .onChange(of: [name, host, port, username, password]) { errorText = nil }
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
            try model.saveProxy(proxy, password: password.isEmpty ? nil : password, isNew: original == nil)
            dismiss()
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
                        .disabled(!model.profiles(using: proxy).isEmpty)
                }
                LabeledContent("协议", value: DisplayText.proxyKind(proxy.kind))
                LabeledContent("服务器", value: proxy.host)
                LabeledContent("端口", value: String(proxy.port))
                LabeledContent("认证", value: proxy.username.map { "用户名：\($0) · 密码保存在钥匙串" } ?? "无认证")
            } footer: {
                Text("独立代理由 WebKit 直接连接，无需 sing-box。修改在关联环境下次启动时生效。")
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
                    Text("正在通过此代理请求 HTTPS…").foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
    }
}

struct ProxyRow: View {
    let proxy: ProxySettings
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(proxy.name).fontWeight(.medium)
                Text("\(DisplayText.proxyKind(proxy.kind)) · \(proxy.host):\(proxy.port)")
                    .font(.caption).foregroundStyle(.secondary)
            }.lineLimit(1)
        } icon: { Image(systemName: "network").foregroundStyle(.blue) }
    }
}
