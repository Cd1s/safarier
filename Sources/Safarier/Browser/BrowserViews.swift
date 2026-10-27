import AppKit
import WebKit
import SafarierCore

/// 页内查找栏（⌘F），和 Safari 一样贴在网页上方。
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    var onFind: ((String, _ backwards: Bool) -> Void)?
    var onClose: (() -> Void)?

    let searchField = NSSearchField()
    private let status = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        searchField.placeholderString = "在页面中查找"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.target = self
        searchField.action = #selector(findNext)

        let previous = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "上一个")!, target: self, action: #selector(findPrevious))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "下一个")!, target: self, action: #selector(findNext))
        for button in [previous, next] { button.bezelStyle = .texturedRounded }
        let done = NSButton(title: "完成", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)

        let spacer = NSView()
        let stack = NSStackView(views: [spacer, status, previous, next, searchField, done])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 240),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(found: Bool?) {
        switch found {
        case .some(true): status.stringValue = ""
        case .some(false): status.stringValue = "未找到"
        case .none: status.stringValue = ""
        }
    }

    @objc func findNext() {
        guard !searchField.stringValue.isEmpty else { return }
        onFind?(searchField.stringValue, false)
    }

    @objc func findPrevious() {
        guard !searchField.stringValue.isEmpty else { return }
        onFind?(searchField.stringValue, true)
    }

    @objc func close() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }
}

/// 新标签页的起始页：环境名、出站、机型，提醒你现在在哪个环境里。不是网页，网站看不到。
@MainActor
final class StartPageView: NSView {
    init(profile: Profile, accent: NSColor, details: [String]) {
        super.init(frame: .zero)
        let avatar = NSTextField(labelWithString: profile.name.first.map { String($0).uppercased() } ?? "?")
        avatar.font = .systemFont(ofSize: 30, weight: .semibold)
        avatar.textColor = .white
        avatar.alignment = .center
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = accent.cgColor
        badge.layer?.cornerRadius = 18
        badge.layer?.cornerCurve = .continuous
        avatar.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(avatar)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 72),
            badge.heightAnchor.constraint(equalToConstant: 72),
            avatar.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            avatar.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])

        let title = NSTextField(labelWithString: profile.name)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let lines = details.map { text -> NSTextField in
            let label = NSTextField(labelWithString: text)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 13)
            return label
        }
        let stack = NSStackView(views: [badge, title] + lines)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(14, after: badge)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }

    /// 起始页没有任何可点控件：永远不拦截鼠标点击，防止覆盖层遮挡底层 WebView 点击。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// 浏览窗口里的 WKWebView：右键菜单照 Safari 改（见 BrowserContextMenu），记下下一次网页打开新视图时要开成窗口还是后台标签。
@MainActor
final class BrowserWebView: WKWebView {
    /// 下一个由网页请求打开的视图开成独立窗口（而不是标签页）。
    var openNextAsWindow = false
    /// 下一个由网页请求打开的视图开成后台标签页（不切过去）。
    var openNextInBackgroundTab = false
    /// 「用 Google 搜索」：在本环境的新标签页里打开这个网址。由标签控制器设置。
    var onSearchWeb: ((URL) -> Void)?
    /// 每次右键「在新窗口 / 后台标签页中打开」加一；两秒后的复位只对同一次生效。
    private var openModeGeneration = 0

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // 右键菜单的其它项由 WebKit 按进程语言（环境的语言设置）本地化，新加的项也跟着走，免得一半中文一半英文。
        BrowserContextMenu.customize(menu, target: self, chinese: Locale.preferredLanguages.first?.hasPrefix("zh") ?? false)
    }

    @objc func openInNewWindow(_ sender: NSMenuItem) {
        forward(sender) { $0.openNextAsWindow = true }
    }

    @objc func openInBackgroundTab(_ sender: NSMenuItem) {
        forward(sender) { $0.openNextInBackgroundTab = true }
    }

    /// 先设好打开方式，再执行 WebKit 原来的「在新窗口中打开」（它会回调 createWebViewWith）。
    /// WebKit 没回调（比如链接被拦下）时两秒后清掉，不影响下一次 window.open。
    private func forward(_ sender: NSMenuItem, prepare: (BrowserWebView) -> Void) {
        guard let original = sender.representedObject as? NSMenuItem, let action = original.action else { return }
        // 先清掉上一次的打开方式；两秒后只复位这一次设的（连续右键时，上一次的定时器不会清掉这一次的设置）。
        openNextAsWindow = false
        openNextInBackgroundTab = false
        openModeGeneration += 1
        let generation = openModeGeneration
        prepare(self)
        NSApp.sendAction(action, to: original.target, from: original)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.openModeGeneration == generation else { return }
            self.openNextAsWindow = false
            self.openNextInBackgroundTab = false
        }
    }

    /// 选中文字用 Safari 默认搜索引擎（Google）在本环境的新标签页里搜，不交给系统默认浏览器。
    @objc func searchWebForSelection(_ sender: NSMenuItem) {
        let fallback = sender.representedObject as? String
        selectedText { [weak self] text in
            let query = (text?.isEmpty == false ? text : fallback)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty, let url = AddressInput.searchURL(query) else { return NSSound.beep() }
            self?.onSearchWeb?(url)
        }
    }

    /// 页面里选中的文字（含输入框里选中的部分，密码框除外）。在独立的脚本环境里读，网页的脚本看不到，也不改页面。
    func selectedText(_ completion: @escaping @MainActor (String?) -> Void) {
        let script = """
        (() => {
          try {
            const e = document.activeElement;
            if (e && (e.tagName === 'TEXTAREA' || (e.tagName === 'INPUT' && e.type !== 'password')) && typeof e.selectionStart === 'number') {
              return e.value.substring(e.selectionStart, e.selectionEnd);
            }
          } catch (_) {}
          return String(window.getSelection() || '');
        })()
        """
        evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            completion(try? result.get() as? String)
        }
    }

    /// 当前 DOM 序列化成 HTML（存储为…用）。同样在独立的脚本环境里读。
    func documentHTML(_ completion: @escaping @MainActor (String?) -> Void) {
        let script = "(document.doctype ? new XMLSerializer().serializeToString(document.doctype) + '\\n' : '') + document.documentElement.outerHTML"
        evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            completion(try? result.get() as? String)
        }
    }
}
