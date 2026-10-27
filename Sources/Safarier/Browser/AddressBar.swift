import AppKit
import SafarierCore

/// Safari 式智能地址栏：不编辑时居中显示域名（https 带锁），点进去显示完整网址并全选；
/// 右侧刷新 / 停止，底部是加载进度条。无痕环境用 Safari 无痕窗口的黑底样式。
@MainActor
final class AddressBar: NSView, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onReload: (() -> Void)?
    var onStop: (() -> Void)?
    /// 按 Esc 取消编辑之后调用（标签控制器把焦点还给网页）。
    var onCancel: (() -> Void)?

    private let field = AddressTextField()
    private let securityIcon = NSImageView()
    private let reloadButton = NSButton()
    private let progress = ProgressLine()
    private let isPrivate: Bool

    private(set) var url: URL?
    private var isLoading = false

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 30))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        build()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        securityIcon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        securityIcon.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.placeholderString = "搜索或输入网站名称"
        field.editingText = { [weak self] in self?.url?.absoluteString ?? "" }
        field.onPasteAndGo = { [weak self] text in
            self?.window?.makeFirstResponder(nil)
            self?.onSubmit?(text)
        }

        reloadButton.isBordered = false
        reloadButton.bezelStyle = .regularSquare
        reloadButton.imagePosition = .imageOnly
        reloadButton.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        reloadButton.contentTintColor = .secondaryLabelColor
        reloadButton.target = self
        reloadButton.action = #selector(reloadOrStop)

        for view in [securityIcon, field, reloadButton, progress] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            securityIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            securityIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            securityIcon.widthAnchor.constraint(equalToConstant: 14),
            field.leadingAnchor.constraint(equalTo: securityIcon.trailingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            reloadButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            reloadButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 18),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
        ])
        let preferred = widthAnchor.constraint(equalToConstant: 480)
        preferred.priority = .defaultLow
        preferred.isActive = true
    }

    override func updateLayer() {
        if isPrivate {
            layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        } else {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.055)).cgColor
        }
    }

    override var wantsUpdateLayer: Bool { true }

    // MARK: - 状态

    func update(url: URL?, isLoading: Bool, progress value: Double, secure: Bool) {
        self.url = url
        self.isLoading = isLoading
        progress.value = isLoading ? max(0.1, value) : 0
        securityIcon.image = Self.securityImage(for: url, secure: secure)
        securityIcon.isHidden = securityIcon.image == nil
        if !field.isEditing { refresh() }
        let symbol = isLoading ? "xmark" : "arrow.clockwise"
        reloadButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: isLoading ? "停止载入此页面" : "重新载入此页面")
        reloadButton.toolTip = isLoading ? "停止载入此页面" : "重新载入此页面"
        reloadButton.isHidden = url == nil && !isLoading
    }

    func focus() {
        window?.makeFirstResponder(field)
    }

    private static func securityImage(for url: URL?, secure: Bool) -> NSImage? {
        guard let scheme = url?.scheme?.lowercased() else { return NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "搜索") }
        switch scheme {
        case "https" where secure: return NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "安全连接")
        case "http", "https": return NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "不安全")
        default: return nil
        }
    }

    /// 不编辑时只显示域名（去掉 www.），和 Safari 默认设置一样。
    private func refresh() {
        let color: NSColor = isPrivate ? .white : .labelColor
        field.textColor = color
        field.alignment = .center
        if let url, let host = url.host {
            field.stringValue = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        } else {
            field.stringValue = url?.absoluteString ?? ""
        }
        if isPrivate {
            field.placeholderAttributedString = NSAttributedString(
                string: "搜索或输入网站名称",
                attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.45), .font: field.font ?? .systemFont(ofSize: 13)]
            )
        }
        field.toolTip = url?.absoluteString
    }

    @objc private func reloadOrStop() {
        isLoading ? onStop?() : onReload?()
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue
            window?.makeFirstResponder(nil)
            onSubmit?(text)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.makeFirstResponder(nil)
            onCancel?()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        field.isEditing = false
        refresh()
    }
}

/// 拿到焦点时切到编辑状态：显示完整网址并全选。
/// 文字要在 super.becomeFirstResponder() 之前换好：编辑中再设 stringValue，AppKit 会直接结束编辑、焦点丢掉。
/// 右键菜单在「粘贴」下面加 Safari 的「粘贴并前往」（剪贴板是网址）/「粘贴并搜索」（其它文字）。
final class AddressTextField: NSTextField {
    var editingText: (() -> String)?
    var isEditing = false
    var onPasteAndGo: ((String) -> Void)?

    static let pasteAndGoIdentifier = NSUserInterfaceItemIdentifier("safarier.pasteAndGo")

    /// 剪贴板里的文字（复制的链接只有 URL 类型时也能取到）。
    static func clipboardText(_ pasteboard: NSPasteboard = .general) -> String? {
        let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// 剪贴板是网址时「粘贴并前往」，是普通文字时「粘贴并搜索」，空的时候不加。
    static func pasteAndGoTitle(for text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = AddressInput.url(for: text) else { return nil }
        return url.absoluteString.hasPrefix(AddressInput.searchURLPrefix) ? "粘贴并搜索" : "粘贴并前往"
    }

    /// 在「粘贴」后面（没有「粘贴」就放最后）插入「粘贴并前往 / 搜索」；已经有了就不再加。
    static func addPasteAndGo(to menu: NSMenu, clipboard: String?, target: AnyObject) {
        guard let title = pasteAndGoTitle(for: clipboard),
              !menu.items.contains(where: { $0.identifier == pasteAndGoIdentifier }) else { return }
        let item = NSMenuItem(title: title, action: #selector(pasteAndGo(_:)), keyEquivalent: "")
        item.identifier = pasteAndGoIdentifier
        item.target = target
        let index = menu.items.firstIndex { $0.action == #selector(NSText.paste(_:)) }.map { $0 + 1 } ?? menu.items.count
        menu.insertItem(item, at: index)
    }

    /// 字段编辑器（NSTextView）的代理是这个文本框：右键菜单弹出前在这里加项。
    @objc(textView:menu:forEvent:atIndex:)
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        Self.addPasteAndGo(to: menu, clipboard: Self.clipboardText(), target: self)
        return menu
    }

    @objc func pasteAndGo(_ sender: Any?) {
        guard let text = Self.clipboardText() else { return NSSound.beep() }
        stringValue = text
        onPasteAndGo?(text)
    }

    override func becomeFirstResponder() -> Bool {
        if !isEditing, let text = editingText?() {
            alignment = .left
            stringValue = text
        }
        let accepted = super.becomeFirstResponder()
        if accepted {
            isEditing = true
            currentEditor()?.selectAll(nil)
        }
        return accepted
    }
}

/// 地址栏底部的蓝色进度线。
final class ProgressLine: NSView {
    var value: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard value > 0 else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * min(1, value), height: bounds.height), xRadius: 1, yRadius: 1).fill()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
