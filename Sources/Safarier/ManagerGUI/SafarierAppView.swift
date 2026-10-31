import SwiftUI
import SafarierCore

/// 管理窗口：左边环境、代理和订阅列表，右边详情。
struct SafarierAppView: View {
    @ObservedObject var model: ManagerModel

    var body: some View {
        NavigationSplitView {
            ManagerSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if let release = model.availableUpdate, !model.isUpdateBannerDismissed {
                    UpdateBannerView(model: model, release: release)
                    Divider()
                }
                detail
            }
        }
        .sheet(item: $model.showingUpdateNotes) { release in
            UpdateNotesSheet(model: model, release: release)
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newProfile: ProfileEditorView(model: model, original: nil)
            case .editProfile(let profile): ProfileEditorView(model: model, original: profile)
            case .newSubscription: SubscriptionEditorView(model: model)
            case .newProxy: ProxyEditorView(model: model, original: nil)
            case .editProxy(let proxy): ProxyEditorView(model: model, original: proxy)
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
            presenting: model.confirmation,
            actions: confirmationActions,
            message: confirmationMessage
        )
        .alert(
            model.message?.title ?? "",
            isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } }),
            presenting: model.message,
            actions: { _ in Button("好") {} },
            message: { Text($0.detail) }
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { ManagerGUI.showAgentSetup() } label: {
                    Label("AI Agent 接入", systemImage: "sparkles")
                }
                .help("同步 Skill 并查看 AI Agent 接入指南")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { AboutAndUpdateController.openGitHub() } label: {
                    Label("查看 GitHub 项目", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help("打开 Safarier 的 GitHub 项目页")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { AboutAndUpdateController.checkForUpdates() } label: {
                    Label("检查更新…", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("检查是否有新版本")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("关于 Safarier") { AboutAndUpdateController.showAbout() }
                    Button("检查更新…") { AboutAndUpdateController.checkForUpdates() }
                    Divider()
                    Button("Safarier GitHub 主页") { AboutAndUpdateController.openGitHub() }
                    Button("查看最新版本 (GitHub Releases)") { AboutAndUpdateController.openReleases() }
                } label: {
                    Label("关于 / GitHub", systemImage: "info.circle")
                }
                .help("关于 Safarier、检查更新、打开 GitHub 页面")
            }
        }
        .onAppear { model.startMonitoring() }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .proxy(let id):
            if let proxy = model.proxy(id) {
                ProxyDetailView(model: model, proxy: proxy)
            } else {
                placeholder
            }
        case .profile(let id):
            if let profile = model.profile(id) {
                ProfileDetailView(model: model, profile: profile)
            } else {
                placeholder
            }
        case .subscription(let id):
            if let subscription = model.subscription(id) {
                SubscriptionDetailView(model: model, subscription: subscription)
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.profiles.isEmpty {
            ContentUnavailableView {
                Label("还没有环境", systemImage: "square.stack.3d.up")
            } description: {
                Text("每个环境有独立的 Cookie、存储、语言、时区和代理，在自己的窗口里运行。")
            } actions: {
                Button("新建环境…") { model.sheet = .newProfile }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else {
            ContentUnavailableView("选择环境、代理或订阅", systemImage: "sidebar.left", description: Text("在左侧列表里选择要查看的项目。"))
        }
    }

    // MARK: - 确认框

    private var confirmationTitle: String {
        switch model.confirmation {
        case .deleteProfile(let profile): return "删除环境「\(profile.name)」？"
        case .purgeProfile(let profile): return "清理「\(profile.name)」的沙盒数据？"
        case .deleteSubscription(let subscription): return "删除订阅「\(subscription.name)」？"
        case .deleteProxy(let proxy): return "删除代理「\(proxy.name)」？"
        case nil: return ""
        }
    }

    @ViewBuilder
    private func confirmationActions(_ confirmation: ManagerModel.Confirmation) -> some View {
        switch confirmation {
        case .deleteProfile(let profile):
            if profile.mode == .persistent {
                Button("删除并清除网站数据", role: .destructive) { model.delete(profile, purgeData: true) }
                Button("只删除环境，保留数据") { model.delete(profile, purgeData: false) }
            } else {
                Button("删除", role: .destructive) { model.delete(profile, purgeData: false) }
            }
        case .purgeProfile(let profile):
            Button("清理", role: .destructive) { model.purgeData(profile) }
        case .deleteSubscription(let subscription):
            Button("删除", role: .destructive) { model.delete(subscription) }
        case .deleteProxy(let proxy):
            Button("删除", role: .destructive) {
                do { try model.deleteProxy(proxy) }
                catch { model.message = .init(title: "删除代理失败", detail: DisplayText.describe(error)) }
            }
        }
        Button("取消", role: .cancel) {}
    }

    private func confirmationMessage(_ confirmation: ManagerModel.Confirmation) -> some View {
        switch confirmation {
        case .deleteProfile(let profile):
            return Text(profile.mode == .persistent
                ? "环境配置会被删除。网站数据（Cookie、登录状态、缓存）可以一起清除，也可以留在磁盘上。"
                : "临时环境没有保存在磁盘上的网站数据。")
        case .purgeProfile:
            return Text("会删除这个环境的 Cookie、登录状态、本地存储和缓存，环境配置保留。此操作不能撤销。")
        case .deleteSubscription:
            return Text("只删除本地保存的订阅链接和节点缓存。")
        case .deleteProxy:
            return Text("删除代理配置及钥匙串中的密码。被环境使用的代理不能删除。")
        }
    }
}

// MARK: - 更新提醒

/// 详情区域顶部的新版本横幅。
struct UpdateBannerView: View {
    @ObservedObject var model: ManagerModel
    let release: ReleaseInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("发现新版本 \(release.tagName)（当前 v\(AboutAndUpdateController.currentVersion)）")
                    .font(.headline)
                if let status = model.updateStatusText {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if model.isInstallingUpdate {
                ProgressView().controlSize(.small)
            }
            Button("点一下重启更新") { model.installAvailableUpdate() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInstallingUpdate)
            Button("查看更新内容") { model.showingUpdateNotes = release }
                .disabled(model.isInstallingUpdate)
            Button("查看 GitHub 项目") { AboutAndUpdateController.openGitHub() }
            Button { model.isUpdateBannerDismissed = true } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("隐藏本次提醒")
            .disabled(model.isInstallingUpdate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12))
    }
}

/// 完整的版本更新说明（纯文本，不渲染 Markdown）。
struct UpdateNotesSheet: View {
    @ObservedObject var model: ManagerModel
    let release: ReleaseInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(release.tagName) 更新内容").font(.title3.bold())
            ScrollView {
                Text(release.body.isEmpty ? release.name : release.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 360)
            if let status = model.updateStatusText {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("查看 GitHub 项目") { AboutAndUpdateController.openGitHub() }
                Spacer()
                if model.isInstallingUpdate { ProgressView().controlSize(.small) }
                Button("立即更新并重启") { model.installAvailableUpdate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInstallingUpdate)
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - 侧边栏

struct ManagerSidebar: View {
    @ObservedObject var model: ManagerModel

    var body: some View {
        List(selection: $model.selection) {
            Section("环境") {
                ForEach(model.profiles) { profile in
                    ProfileRow(profile: profile, proxy: model.proxyBinding(for: profile), state: model.runState(profile.id))
                        .tag(ManagerModel.Selection.profile(profile.id))
                        .contextMenu { profileMenu(profile) }
                }
                if model.profiles.isEmpty {
                    Text("还没有环境").foregroundStyle(.tertiary)
                }
            }
            Section("代理") {
                ForEach(model.proxies) { proxy in
                    ProxyRow(proxy: proxy)
                        .tag(ManagerModel.Selection.proxy(proxy.id))
                        .contextMenu {
                            Button("编辑代理…") { model.sheet = .editProxy(proxy) }
                            Button("删除代理…", role: .destructive) { model.confirmation = .deleteProxy(proxy) }
                                .disabled(!model.profiles(using: proxy).isEmpty)
                        }
                }
                if model.proxies.isEmpty { Text("还没有代理").foregroundStyle(.tertiary) }
                Button { model.sheet = .newProxy } label: {
                    Label("添加代理…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Section("订阅") {
                ForEach(model.subscriptions) { subscription in
                    SubscriptionRow(subscription: subscription, refreshing: model.refreshing.contains(subscription.id))
                        .tag(ManagerModel.Selection.subscription(subscription.id))
                        .contextMenu {
                            Button("刷新订阅") { model.refresh(subscription) }
                            Divider()
                            Button("删除订阅…", role: .destructive) { model.confirmation = .deleteSubscription(subscription) }
                        }
                }
                if model.subscriptions.isEmpty {
                    Text("还没有订阅").foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 14) {
                    Button { model.sheet = .newProfile } label: { Label("新建环境", systemImage: "plus") }
                    Button { model.sheet = .newSubscription } label: { Label("添加订阅", systemImage: "plus") }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
    }

    @ViewBuilder
    private func profileMenu(_ profile: Profile) -> some View {
        let state = model.runState(profile.id)
        if state == .running {
            Button("切换到窗口") { model.bringToFront(profile) }
            Button("结束运行") { model.stop(profile) }
        } else {
            Button("启动浏览器") { model.launch(profile) }
                .disabled(state != .stopped)
        }
        Button("编辑…") { model.sheet = .editProfile(profile) }
        Button("复制环境") { model.duplicate(profile) }
        Divider()
        Button("清理沙盒数据…") { model.confirmation = .purgeProfile(profile) }
            .disabled(profile.mode == .ephemeral || state != .stopped)
        Button("删除环境…", role: .destructive) { model.confirmation = .deleteProfile(profile) }
            .disabled(state != .stopped)
    }
}

struct ProfileRow: View {
    let profile: Profile
    let proxy: ProxyBinding
    let state: RunState

    var body: some View {
        HStack(spacing: 10) {
            ProfileAvatar(profile: profile, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    ModeBadge(mode: profile.mode)
                    RunStateDot(state: state)
                }
                HStack(spacing: 10) {
                    Label(DisplayText.proxyName(proxy), systemImage: proxySymbol)
                    Label(DisplayText.shortTimeZone(of: profile), systemImage: "clock")
                }
                .labelStyle(CompactLabelStyle())
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var proxySymbol: String {
        switch proxy {
        case .direct: return "arrow.up.right"
        case .proxy, .custom: return "network"
        case .node: return "antenna.radiowaves.left.and.right"
        case .missing, .missingNode: return "exclamationmark.triangle"
        }
    }
}

struct SubscriptionRow: View {
    let subscription: Subscription
    let refreshing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.indigo.gradient))
            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.name).fontWeight(.medium).lineLimit(1)
                Text("\(subscription.nodes.count) 个节点")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if refreshing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 小部件

/// 名字首字母 + 按 id 固定的颜色，方便在多个窗口之间认出同一个环境。
struct ProfileAvatar: View {
    let profile: Profile
    let size: CGFloat

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .mint, .brown]

    var body: some View {
        let color = Self.palette[Int(profile.id.uuid.0) % Self.palette.count]
        Text(profile.name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24).fill(color.gradient))
    }
}

struct ModeBadge: View {
    let mode: ProfileMode
    var large = false

    var body: some View {
        let color: Color = mode == .persistent ? .blue : .orange
        Text(DisplayText.mode(mode))
            .font(large ? .callout.weight(.semibold) : .caption2.weight(.semibold))
            .padding(.horizontal, large ? 8 : 5)
            .padding(.vertical, large ? 2 : 1)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct RunStateDot: View {
    let state: RunState

    var body: some View {
        switch state {
        case .stopped:
            EmptyView()
        case .starting:
            Circle().fill(.orange).frame(width: 7, height: 7).help("正在启动")
        case .running:
            Circle().fill(.green).frame(width: 7, height: 7).help("运行中")
        }
    }
}

struct ProtocolBadge: View {
    let type: SubscriptionNodeType

    var body: some View {
        let color = DisplayText.nodeColor(type)
        Text(DisplayText.nodeType(type))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}
