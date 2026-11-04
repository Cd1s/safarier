import AppKit
import SwiftUI
import SafarierCore

/// 详情页直接编辑配置，新建环境仍使用独立表单。
struct ProfileDetailView: View {
    @ObservedObject var model: ManagerModel
    let profile: Profile

    var body: some View {
        ProfileEditorView(model: model, original: profile, inline: true)
            .id(profile.id)
            .navigationTitle(profile.name)
            .navigationSubtitle(model.runState(profile.id) == .running ? "运行中" : DisplayText.mode(profile.mode))
    }
}

struct ProfileDetailHeader: View {
    @ObservedObject var model: ManagerModel
    let profile: Profile
    @ObservedObject var editor: ProfileEditorState

    var body: some View {
        let state = model.runState(profile.id)
        header(state)
        actions(state)
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
            .disabled(editor.hasChanges || editor.isSaving)
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
            Button { model.duplicate(profile) } label: { Label("复制环境", systemImage: "plus.square.on.square") }
                .help("复制全部设置，新环境不带 Cookie 和登录状态")
                .disabled(editor.hasChanges || editor.isSaving)
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

}

struct ProfileMetadataSections: View {
    @ObservedObject var model: ManagerModel
    let profile: Profile

    var body: some View {
        Section("沙盒与日志") {
            if profile.mode == .persistent {
                LabeledContent("网站数据") {
                    fileLocation(DisplayText.webKitDataDirectory(for: profile.id), missing: "尚未创建（首次启动后生成）")
                }
            }
            LabeledContent("运行日志") {
                fileLocation(model.workspace.runnerLogURL(for: profile.id), missing: "还没有日志")
            }
        }
        Section("环境信息") {
            LabeledContent("创建时间", value: profile.createdAt.formatted(date: .long, time: .shortened))
            LabeledContent("环境 ID") {
                Text(profile.id.uuidString).font(.system(.body, design: .monospaced)).textSelection(.enabled)
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
