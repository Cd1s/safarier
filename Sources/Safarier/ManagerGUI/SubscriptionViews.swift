import SwiftUI
import SafarierCore

/// 选中订阅时的详情：链接、更新时间、节点表。节点表不显示 UUID / 密码。
struct SubscriptionDetailView: View {
    @ObservedObject var model: ManagerModel
    let subscription: Subscription

    var body: some View {
        let refreshing = model.refreshing.contains(subscription.id)
        let usage = Dictionary(grouping: model.profiles(using: subscription), by: { $0.nodeName ?? "" })
        VStack(alignment: .leading, spacing: 0) {
            header(refreshing)
                .padding(20)
            Divider()
            if subscription.nodes.isEmpty {
                ContentUnavailableView(
                    "没有节点",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("订阅里没有可识别的节点，点「刷新订阅」重新拉取。")
                )
            } else {
                Table(subscription.nodes) {
                    TableColumn("名称", value: \.name)
                    TableColumn("协议") { node in ProtocolBadge(type: node.type) }
                        .width(min: 60, ideal: 70, max: 90)
                    TableColumn("服务器") { node in
                        Text(verbatim: "\(node.server):\(node.serverPort)").monospaced()
                    }
                    TableColumn("传输") { node in Text(node.transport ?? "tcp") }
                        .width(min: 50, ideal: 60, max: 90)
                    TableColumn("TLS") { node in
                        if node.tls {
                            Image(systemName: "lock.fill").foregroundStyle(.green).help(node.serverName ?? "TLS")
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 36, ideal: 40, max: 60)
                    TableColumn("绑定环境") { node in
                        Text(usage[node.name]?.map(\.name).joined(separator: "、") ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 110)
                }
            }
        }
        .navigationTitle(subscription.name)
        .navigationSubtitle("\(subscription.nodes.count) 个节点")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.refresh(subscription) } label: { Label("刷新订阅", systemImage: "arrow.clockwise") }
                    .help("刷新订阅")
                    .disabled(refreshing)
            }
        }
    }

    private func header(_ refreshing: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 13).fill(Color.indigo.gradient))
            VStack(alignment: .leading, spacing: 6) {
                Text(subscription.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(model.isInline(subscription) ? "直接粘贴的节点链接（保存在本机）" : subscription.url.absoluteString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    ForEach(protocolCounts, id: \.type) { item in
                        HStack(spacing: 3) {
                            ProtocolBadge(type: item.type)
                            Text("\(item.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(updatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 8) {
                Button { model.refresh(subscription) } label: {
                    HStack(spacing: 6) {
                        if refreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(refreshing ? "正在刷新…" : "刷新订阅")
                    }
                    .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(refreshing)
                Button(role: .destructive) { model.confirmation = .deleteSubscription(subscription) } label: {
                    Label("删除…", systemImage: "trash")
                }
                .disabled(refreshing)
            }
        }
    }

    private var protocolCounts: [(type: SubscriptionNodeType, count: Int)] {
        SubscriptionNodeType.allCases.compactMap { type in
            let count = subscription.nodes.filter { $0.type == type }.count
            return count == 0 ? nil : (type, count)
        }
    }

    private var updatedText: String {
        guard let updatedAt = subscription.updatedAt else { return "从未更新" }
        return "· 更新于 " + updatedAt.formatted(.relative(presentation: .named))
    }
}

/// 添加订阅：与命令行 `sub add` 一样，先拉取（或解析粘贴的节点链接）成功再保存。
struct SubscriptionEditorView: View {
    @ObservedObject var model: ManagerModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $name, prompt: Text("例如：机场 A"))
                    TextField("订阅链接", text: $url, prompt: Text("https://… 或直接粘贴 ss:// vless:// 等节点链接"), axis: .vertical)
                        .lineLimit(1...6)
                } header: {
                    Text("添加订阅")
                } footer: {
                    Text("填订阅网址（内容可以是 Base64 或逐行的节点链接），或者直接粘贴一条或多条节点链接：ss:// ss2022:// vless:// vmess:// trojan:// anytls:// socks://。添加时会立即解析一次节点；直接粘贴的链接保存在本机，hysteria2 等暂不支持的协议会跳过。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(busy)

            Divider()
            HStack(spacing: 10) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("正在拉取节点…").foregroundStyle(.secondary)
                } else if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 330)
        .onChange(of: [name, url]) { errorText = nil }
    }

    private func submit() {
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        errorText = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.addSubscription(name: name.trimmingCharacters(in: .whitespacesAndNewlines), input: raw)
                dismiss()
            } catch {
                errorText = DisplayText.describe(error)
            }
        }
    }
}
