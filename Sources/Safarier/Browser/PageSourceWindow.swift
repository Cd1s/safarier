import AppKit

/// 「显示页面源代码」（⌥⌘U）：原生窗口里用等宽字体显示源代码，标签、属性值、注释上色，带「拷贝」按钮。
/// 只读，不是网页，网站看不到。
@MainActor
final class PageSourceWindowController: NSObject, NSWindowDelegate {
    /// 超过这个长度不上色（正则对几 MB 的页面太慢），只用等宽字体显示。
    static let highlightLimit = 1_500_000

    let window: NSWindow
    let source: String
    var onClose: ((PageSourceWindowController) -> Void)?
    let textView: NSTextView

    init(source: String, title: String, url: URL?) {
        self.source = source
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init()

        window.isReleasedWhenClosed = false
        // 源代码窗口不和浏览窗口合并成标签。
        window.tabbingMode = .disallowed
        window.title = "源代码 — \(title)"
        window.delegate = self
        window.minSize = NSSize(width: 420, height: 240)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textStorage?.setAttributedString(Self.highlighted(source))

        let address = NSTextField(labelWithString: url?.absoluteString ?? "")
        address.font = .systemFont(ofSize: 12)
        address.textColor = .secondaryLabelColor
        address.lineBreakMode = .byTruncatingMiddle
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let copy = NSButton(title: "拷贝", target: self, action: #selector(copySource(_:)))
        copy.bezelStyle = .rounded
        let bar = NSStackView(views: [address, NSView(), copy])
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        let line = NSBox()
        line.boxType = .separator

        let stack = NSStackView(views: [bar, line, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        for view in [bar, line, scroll] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window.contentView = stack
    }

    func show(relativeTo parent: NSWindow?) {
        if let parent {
            window.setFrameTopLeftPoint(parent.cascadeTopLeft(from: NSPoint(x: parent.frame.minX, y: parent.frame.maxY)))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    // 菜单栏的 ⌘W / ⇧⌘W / ⌘F / ⌘G / ⇧⌘G / ⌘E 沿响应链先到这里（窗口代理）：关窗口，或交给文本视图的查找栏。
    @objc func closeTab(_ sender: Any?) { window.performClose(sender) }
    @objc func closeWindow(_ sender: Any?) { window.performClose(sender) }
    @objc func showFind(_ sender: Any?) { sendFinderAction(.showFindInterface) }
    @objc func findNextMatch(_ sender: Any?) { sendFinderAction(.nextMatch) }
    @objc func findPreviousMatch(_ sender: Any?) { sendFinderAction(.previousMatch) }
    @objc func useSelectionForFind(_ sender: Any?) { sendFinderAction(.setSearchString) }

    private func sendFinderAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    @objc func copySource(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(source, forType: .string)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    /// 简单的 HTML 上色：注释灰色、标签名紫色、属性名橙色、属性值蓝色。
    static func highlighted(_ source: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let text = NSMutableAttributedString(string: source, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        let length = (source as NSString).length
        guard length <= highlightLimit else { return text }
        let rules: [(pattern: String, group: Int, color: NSColor)] = [
            (#"</?([A-Za-z][A-Za-z0-9:-]*)"#, 1, .systemPurple),
            (#"\s([A-Za-z_:@][-A-Za-z0-9_:.@]*)\s*="#, 1, .systemOrange),
            (#"=\s*("[^"]*"|'[^']*')"#, 1, .systemBlue),
            (#"<!--[\s\S]*?-->"#, 0, .systemGray),
            (#"<!DOCTYPE[^>]*>"#, 0, .systemGray),
        ]
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: source, range: NSRange(location: 0, length: length)) {
                let range = match.range(at: rule.group)
                if range.location != NSNotFound { text.addAttribute(.foregroundColor, value: rule.color, range: range) }
            }
        }
        return text
    }

    /// 页面原文按 UTF-8 解码，不是 UTF-8 时退回 Latin-1（不会失败）。
    static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}
