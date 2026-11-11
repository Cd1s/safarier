import SwiftUI
import SafarierCore

/// 节点与完整代理链复用同一显示规则；耗时来自经过代理的 HTTPS 请求。
struct ProxyLatencyView: View {
    let state: ManagerModel.ProxyTestState?

    var body: some View {
        switch state {
        case .queued:
            Text("等待测试").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.mini).help("正在测试延迟…")
        case .success(let result):
            Text(L10n.text("%lld ms", Int((result.duration * 1000).rounded())))
                .monospacedDigit()
                .foregroundStyle(result.duration < 0.5 ? Color.green : (result.duration < 1.5 ? Color.orange : Color.red))
                .help(L10n.text("HTTPS 请求耗时 · %@", result.testedAt.formatted(date: .omitted, time: .standard)))
        case .failure(let message):
            Label("失败", systemImage: "exclamationmark.circle").foregroundStyle(.red).help(message)
        case nil:
            Text("尚未测试").foregroundStyle(.secondary)
        }
    }
}
