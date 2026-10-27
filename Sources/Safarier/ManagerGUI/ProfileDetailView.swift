import AppKit
import SwiftUI
import SafarierCore

/// 选中环境时的详情：启动按钮 + 全部参数。
struct ProfileDetailView: View {
    @ObservedObject var model: ManagerModel
    let profile: Profile

    var body: some View {
        let state = model.runState(profile.id)
        Form {
            Section {
                header(state)
                actions(state)
            }

            Section("网络") {
                LabeledContent("出站") { proxyDescription }
            }

            Section("区域与语言") {
                LabeledContent("语言", value: DisplayText.languages(of: profile))
                LabeledContent("时区", value: DisplayText.timeZone(of: profile))
            }

            Section {
                if let model = profile.deviceModel.flatMap(MacDeviceModel.preset) {
                    LabeledContent("机型", value: model.name)
                    LabeledContent("芯片规格", value: DisplayText.hardware(model))
                    LabeledContent("屏幕", value: DisplayText.screen(model))
                    LabeledContent("网页看到的", value: DisplayText.webVisible(model))
                    LabeledContent("推荐视口", value: DisplayText.viewport(model))
                } else {
                    LabeledContent("机型") {
                        if let id = profile.deviceModel {
                            Label("未知机型（\(id)），按跟随系统处理", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        } else {
                            Text("跟随系统（默认）")
                        }
                    }
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
                    spiRow(token.feature)
                }
            } header: {
                Text("隐私与指纹保护")
            } footer: {
                Text("基于系统 WebKit 原生能力实现，不向网页注入任何篡改脚本。启动时逐项探测，不可用时安全降级，结果写进日志的 [spi] 行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("沙盒") {
                LabeledContent("模式") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(DisplayText.mode(profile.mode))
                        Text(DisplayText.modeDetail(profile.mode)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if profile.mode == .persistent {
                    LabeledContent("网站数据") { fileLocation(DisplayText.webKitDataDirectory(for: profile.id), missing: "尚未创建（首次启动后生成）") }
                }
                LabeledContent("运行日志") { fileLocation(model.workspace.runnerLogURL(for: profile.id), missing: "还没有日志") }
            }

            Section("其他") {
                LabeledContent("起始网址") {
                    if let url = profile.startURL {
                        Text(url.absoluteString).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("空白页，启动后在地址栏输入").foregroundStyle(.secondary)
                    }
                }
                if !profile.notes.isEmpty {
                    LabeledContent("备注", value: profile.notes)
                }
                LabeledContent("创建时间", value: profile.createdAt.formatted(date: .long, time: .shortened))
                LabeledContent("环境 ID") {
                    Text(profile.id.uuidString).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(profile.name)
        .navigationSubtitle(state == .running ? "运行中" : DisplayText.mode(profile.mode))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.sheet = .editProfile(profile) } label: { Label("编辑", systemImage: "pencil") }
                    .help("编辑环境")
                Button { model.duplicate(profile) } label: { Label("复制环境", systemImage: "plus.square.on.square") }
                    .help("复制环境（不复制网站数据）")
                Button { model.launch(profile) } label: { Label("启动浏览器", systemImage: "play.fill") }
                    .help("启动浏览器")
                    .disabled(state != .stopped)
            }
        }
    }

    // MARK: - 头部

    private func header(_ state: RunState) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ProfileAvatar(profile: profile, size: 60)
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    ModeBadge(mode: profile.mode, large: true)
                    stateLabel(state)
                }
            }
            Spacer(minLength: 16)
            launchControl(state)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func stateLabel(_ state: RunState) -> some View {
        switch state {
        case .stopped:
            Text("未运行").font(.callout).foregroundStyle(.secondary)
        case .starting:
            Label("正在启动", systemImage: "circle.fill").font(.callout).foregroundStyle(.orange).labelStyle(CompactLabelStyle())
        case .running:
            Label("运行中", systemImage: "circle.fill").font(.callout).foregroundStyle(.green).labelStyle(CompactLabelStyle())
        }
    }

    @ViewBuilder
    private func launchControl(_ state: RunState) -> some View {
        switch state {
        case .stopped:
            Button { model.launch(profile) } label: {
                Label("启动浏览器", systemImage: "play.fill")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
        case .starting:
            Button {} label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在启动…")
                }
                .frame(minWidth: 150)
            }
            .controlSize(.extraLarge)
            .disabled(true)
        case .running:
            VStack(alignment: .trailing, spacing: 6) {
                Button { model.bringToFront(profile) } label: {
                    Label("切换到窗口", systemImage: "macwindow")
                        .frame(minWidth: 150)
                }
                .controlSize(.extraLarge)
                Button("结束运行") { model.stop(profile) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    private func actions(_ state: RunState) -> some View {
        let purging = model.purging.contains(profile.id)
        return HStack(spacing: 10) {
            Button { model.sheet = .editProfile(profile) } label: { Label("编辑…", systemImage: "pencil") }
            Button { model.duplicate(profile) } label: { Label("复制环境", systemImage: "plus.square.on.square") }
                .help("复制全部设置，新环境不带 Cookie 和登录状态")
            Button { model.confirmation = .purgeProfile(profile) } label: {
                Label(purging ? "正在清理…" : "清理沙盒数据…", systemImage: "eraser")
            }
            .disabled(profile.mode == .ephemeral || state != .stopped || purging)
            .help(profile.mode == .ephemeral ? "临时环境不在磁盘上保存网站数据" : "删除 Cookie、登录状态、本地存储和缓存")
            Spacer()
            Button(role: .destructive) { model.confirmation = .deleteProfile(profile) } label: {
                Label("删除…", systemImage: "trash")
            }
            .disabled(state != .stopped || purging)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 行

    @ViewBuilder
    private var proxyDescription: some View {
        switch model.proxyBinding(for: profile) {
        case .direct:
            Text("直连（不经过代理）")
        case .proxy(let proxy):
            VStack(alignment: .trailing, spacing: 2) {
                Text(proxy.name)
                Text(verbatim: "\(DisplayText.proxyKind(proxy.kind)) · \(proxy.host):\(proxy.port)" + (proxy.username.map { " · 用户 \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .missing(let id):
            Label("代理已被删除（\(id.uuidString.prefix(8))），启动会失败", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .node(let subscription, let node):
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(node.name) (\(DisplayText.nodeType(node.type)))")
                Text(verbatim: "订阅「\(subscription.name)」· \(node.server):\(node.serverPort) · 经 sing-box 转本地 SOCKS5")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .missingNode(let subscription, let node):
            Label(
                subscription.map { "订阅「\($0)」里已没有节点「\(node)」，启动会失败" } ?? "绑定的订阅已被删除，启动会失败",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        }
    }

    private func spiRow(_ feature: SPIFeatures) -> some View {
        let text = DisplayText.spi(feature)
        let enabled = profile.spi.contains(feature)
        return LabeledContent {
            if enabled, feature == .engineTimeZone, profile.timeZoneIdentifier == nil, !profile.followProxyTimeZone {
                Label("开启（跟随系统）", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if enabled {
                Label("开启", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("关闭").foregroundStyle(.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title)
                Text(text.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func fileLocation(_ url: URL, missing: String) -> some View {
        if FileManager.default.fileExists(atPath: url.path) {
            HStack(spacing: 6) {
                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path)
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("在访达中显示")
            }
        } else {
            Text(missing).foregroundStyle(.secondary)
        }
    }
}
