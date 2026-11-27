import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SafarierCore

struct CookieImportView: View {
    @ObservedObject var model: ManagerModel
    let profile: Profile
    @Environment(\.dismiss) private var dismiss

    @State private var rawText = ""
    @State private var isImporting = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("导入 Cookie — %@", profile.name))
                        .font(.headline)
                    Text("支持粘贴 JSON 数组（EditThisCookie / Cookie-Editor / AdsPower）或 Netscape cookies.txt，也可以选择本地文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("选择文件…") { chooseFile() }
                    .disabled(isImporting)
            }

            TextEditor(text: $rawText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 240)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .disabled(isImporting)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                if isImporting {
                    ProgressView().controlSize(.small)
                }
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                Button("导入") { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting || rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onChange(of: rawText) { errorText = nil }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, .plainText, .text]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            rawText = try String(contentsOf: url, encoding: .utf8)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func runImport() {
        errorText = nil
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let result = try await model.importCookies(from: rawText, for: profile)
                dismiss()
                let detail = result.skippedCount > 0
                    ? L10n.text("已导入 %lld 条 Cookie（跳过 %lld 条无效项）。", result.cookies.count, result.skippedCount)
                    : L10n.text("已导入 %lld 条 Cookie。", result.cookies.count)
                model.message = ManagerModel.Message(title: L10n.text("导入成功"), detail: detail)
            } catch {
                errorText = DisplayText.describe(error)
            }
        }
    }
}
