import SwiftUI
import AppKit
import SafarierCore

/// 选中订阅时的详情：链接、更新时间、节点表。节点表不显示 UUID / 密码。
struct SubscriptionDetailView: View {
    @ObservedObject var model: ManagerModel
    let subscription: Subscription

    var body: some View {
        let refreshing = model.refreshing.contains(subscription.id)
        let usage = Dictionary(grouping: model.profiles.filter { $0.subscriptionID == subscription.id }, by: { $0.nodeName ?? "" })
        let upstreamUsage = Dictionary(grouping: model.proxies(using: subscription), by: { $0.upstream?.nodeName ?? "" })
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
                    TableColumn("HTTPS 延迟") { node in
                        HStack {
                            ProxyLatencyView(state: model.nodeTestState(subscriptionID: subscription.id, node: node))
                            Spacer(minLength: 4)
                            Button { model.testNodes([node], subscriptionID: subscription.id) } label: {
                                Image(systemName: "speedometer")
                            }
                            .buttonStyle(.borderless)
                            .help("测试延迟")
                            .disabled(model.nodeTestState(subscriptionID: subscription.id, node: node) == .running
                                      || model.nodeTestState(subscriptionID: subscription.id, node: node) == .queued)
                        }
                    }
                    .width(min: 110, ideal: 130, max: 180)
                    TableColumn("绑定环境") { node in
                        Text(usage[node.name]?.map(\.name).joined(separator: L10n.text("、")) ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 110)
                    TableColumn("用作前置") { node in
                        Text(upstreamUsage[node.name]?.map(\.name).joined(separator: L10n.text("、")) ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 110)
                }
            }
        }
        .navigationTitle(subscription.name)
        .navigationSubtitle(L10n.text("%lld 个节点", subscription.nodes.count))
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
                Text(model.isInline(subscription) ? L10n.text("直接粘贴的节点链接（保存在本机）") : subscription.url.absoluteString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    ForEach(protocolCounts, id: \.type) { item in
                        HStack(spacing: 3) {
                            ProtocolBadge(type: item.type)
                            Text(verbatim: "\(item.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(updatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 8) {
                if model.isTestingNodes(subscriptionID: subscription.id) {
                    Button("取消测试") { model.cancelNodeTests(subscriptionID: subscription.id) }
                } else {
                    Button("测试全部延迟") { model.testNodes(subscription.nodes, subscriptionID: subscription.id) }
                        .disabled(subscription.nodes.isEmpty || refreshing)
                }
                Button { model.refresh(subscription) } label: {
                    HStack(spacing: 6) {
                        if refreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(refreshing ? L10n.text("正在刷新…") : L10n.text("刷新订阅"))
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
        guard let updatedAt = subscription.updatedAt else { return L10n.text("从未更新") }
        return L10n.text("· 更新于 %@", updatedAt.formatted(.relative(presentation: .named)))
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
                        .autocorrectionDisabled()
                        .lineLimit(1...6)
                    Button("选择 Clash YAML 文件…") { chooseFile() }
                } header: {
                    Text("添加订阅")
                } footer: {
                    Text("可填写订阅网址、粘贴节点链接或 Clash YAML，也可选择本地文件。Clash 支持 Trojan、AnyTLS、VLESS / Reality、Mieru 和 Hysteria2；只导入节点，不应用文件中的路由或 DNS 设置。")
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
        .frame(width: 560, height: 380)
        .onChange(of: [name, url]) { errorText = nil }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let file = panel.url {
            url = file.absoluteString
            if name.isEmpty { name = file.deletingPathExtension().lastPathComponent }
        }
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
