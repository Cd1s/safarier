import SwiftUI
import SafarierCore
import SafarierNetwork

struct ManualProxyDraft {
    var kind: ProxyKind = .socks5
    var host = "127.0.0.1"
    var port = "1080"
    var username = ""
    var password = ""

    init() {}

    /// 只有表单能完整表达的配置才回填；额外字段保留在高级编辑器中。
    init?(json: String) {
        guard let object = try? CustomOutbound.parse(json),
              Set(object.keys).isSubset(of: ["type", "tag", "server", "server_port", "version", "username", "password"]),
              case .string(let type) = object["type"], ["socks", "http"].contains(type),
              type != "socks" || object["version"] == nil || object["version"] == .string("5"),
              case .string(let server) = object["server"], case .number(let serverPort) = object["server_port"] else { return nil }
        kind = type == "socks" ? .socks5 : .httpConnect
        host = server
        port = String(serverPort)
        if case .string(let value) = object["username"] { username = value }
        if case .string(let value) = object["password"] { password = value }
    }

    func json() throws -> String {
        guard let port = Int(port) else { throw CustomOutboundError.invalidEndpoint }
        return try CustomOutbound.manual(kind: kind, host: host, port: port, username: username, password: password)
    }
}

struct ManualProxyFields: View {
    @Binding var draft: ManualProxyDraft

    var body: some View {
        Picker("协议", selection: $draft.kind) {
            Text("SOCKS5").tag(ProxyKind.socks5)
            Text("HTTP CONNECT").tag(ProxyKind.httpConnect)
        }
        TextField("服务器", text: $draft.host, prompt: Text("主机名或 IP 地址"))
        TextField("端口", text: $draft.port)
        TextField("用户名", text: $draft.username, prompt: Text("无认证时留空"))
        SecureField("密码", text: $draft.password, prompt: Text("无认证时留空"))
    }
}

struct CustomOutboundJSONEditor: View {
    @Binding var json: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("sing-box 出站 JSON")
                Spacer()
                Button("恢复 SOCKS5 模板") { json = CustomOutbound.defaultJSON }
            }
            TextEditor(text: $json)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 190)
                .accessibilityLabel("sing-box 出站 JSON")
            Text("填写一个出站对象，不是完整配置。可包含认证信息；复制或分享前请移除密码。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
