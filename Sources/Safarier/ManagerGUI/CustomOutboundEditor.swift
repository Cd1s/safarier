import SwiftUI
import SafarierNetwork

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
                .autocorrectionDisabled()
                .frame(minHeight: 190)
                .accessibilityLabel("sing-box 出站 JSON")
            Text("填写一个出站对象，不是完整配置。可包含认证信息；复制或分享前请移除密码。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
