import AppKit
import WebKit

/// 一个环境（Runner 进程）里的下载：存到「下载」文件夹，重名自动加序号；走的是这个环境的网络（同一代理）。
@MainActor
final class DownloadsController: NSObject, WKDownloadDelegate {
    @MainActor
    final class Item {
        let download: WKDownload
        var destination: URL?
        var finished = false
        var failure: String?
        var observation: NSKeyValueObservation?

        init(download: WKDownload) { self.download = download }

        var name: String { destination?.lastPathComponent ?? download.originalRequest?.url?.lastPathComponent ?? "下载" }
    }

    private(set) var items: [Item] = []
    /// 有新下载或进度变化时通知（窗口据此显示工具栏按钮、刷新列表）。
    var onChange: (() -> Void)?
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) {
        self.directory = directory
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        let item = Item(download: download)
        item.observation = download.progress.observe(\.fractionCompleted) { [weak self] _, _ in
            DispatchQueue.main.async { self?.onChange?() }
        }
        items.insert(item, at: 0)
        onChange?()
    }

    private func item(for download: WKDownload) -> Item? {
        items.first { $0.download === download }
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let url = uniqueDestination(for: suggestedFilename.isEmpty ? "download" : suggestedFilename)
        item(for: download)?.destination = url
        onChange?()
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.finished = true
        onChange?()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        item.failure = error.localizedDescription
        onChange?()
    }

    private func uniqueDestination(for filename: String) -> URL {
        let safe = filename.replacingOccurrences(of: "/", with: "-")
        var candidate = directory.appendingPathComponent(safe)
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    // MARK: - 弹出列表

    func makePopoverContent() -> NSViewController {
        let controller = NSViewController()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let title = NSTextField(labelWithString: "下载")
        title.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(title)
        for item in items.prefix(12) {
            stack.addArrangedSubview(row(for: item))
        }
        if items.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: "没有下载"))
        }
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: stack.fittingSize.height)
        controller.view = stack
        controller.preferredContentSize = NSSize(width: 340, height: stack.fittingSize.height)
        return controller
    }

    private func row(for item: Item) -> NSView {
        let name = NSTextField(labelWithString: item.name)
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 12, weight: .medium)
        let status: String
        if let failure = item.failure {
            status = "失败：\(failure)"
        } else if item.finished {
            status = "已完成"
        } else {
            let progress = item.download.progress
            status = progress.totalUnitCount > 0
                ? "\(ByteCountFormatter.string(fromByteCount: progress.completedUnitCount, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalUnitCount, countStyle: .file))"
                : "正在下载…"
        }
        let detail = NSTextField(labelWithString: status)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = item.failure == nil ? .secondaryLabelColor : .systemRed
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        var views: [NSView] = [text]
        if !item.finished, item.failure == nil {
            let bar = NSProgressIndicator()
            bar.isIndeterminate = item.download.progress.totalUnitCount <= 0
            bar.doubleValue = item.download.progress.fractionCompleted * 100
            bar.style = .bar
            bar.controlSize = .small
            bar.widthAnchor.constraint(equalToConstant: 80).isActive = true
            if bar.isIndeterminate { bar.startAnimation(nil) }
            views.append(bar)
        } else if let destination = item.destination, item.finished {
            let reveal = NSButton(image: NSImage(systemSymbolName: "magnifyingglass.circle.fill", accessibilityDescription: "在访达中显示")!, target: nil, action: nil)
            reveal.isBordered = false
            reveal.toolTip = "在访达中显示"
            let action = RevealAction(url: destination)
            reveal.target = action
            reveal.action = #selector(RevealAction.reveal)
            objc_setAssociatedObject(reveal, &RevealAction.key, action, .OBJC_ASSOCIATION_RETAIN)
            views.append(reveal)
        }
        let row = NSStackView(views: views)
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 316).isActive = true
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }
}

private final class RevealAction: NSObject {
    nonisolated(unsafe) static var key = 0
    let url: URL
    init(url: URL) { self.url = url }
    @objc func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
