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

// MARK: - 起始页

/// 新标签页的起始页，照真 Safari 起始页做：个人收藏、建议（当前环境、出口网络、AI 快捷入口）、隐私报告，右下角「编辑」。
/// 不是网页，网站看不到。磁贴图标都在本地画，不联网取：起始页在 Runner 进程里，联网会绕过这个环境的代理。
/// 点磁贴或卡片时交给 `onOpenURL`；没设置时在同一窗口里找到 BrowserWebView 直接载入，并立刻隐藏起始页，不挡网页的点击。
@MainActor
final class StartPageView: NSView {
    /// 起始页上显示的环境信息：来自 Profile 和 BrowserSession.startPageDetails（出站、机型、语言时区）。
    struct Summary: Equatable {
        var name: String
        var isPrivate: Bool
        var mode: String
        var device: String?
        var outbound: String
        var isDirect: Bool
        var region: String
        /// 开着的原生保护项。
        var protections: [String]
        var advancedPrivacy: Bool
        var fontAllowlist: Bool

        init(profile: Profile, details: [String]) {
            func value(after prefix: String) -> String? {
                details.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            }
            name = profile.name
            isPrivate = profile.mode == .ephemeral
            mode = isPrivate ? "临时环境" : "持久环境"
            device = value(after: "机型：")
            outbound = value(after: "出站：") ?? "直连"
            isDirect = outbound == "直连"
            let following = profile.followProxyLanguages || profile.followProxyTimeZone
            region = details.first { $0.hasPrefix("语言：") || $0.hasPrefix("时区：") }
                ?? (following ? "语言和时区跟随代理出口" : "语言和时区跟随系统")
            let named: [(SPIFeatures, String)] = [
                (.fingerprintingProtections, "高级隐私保护"), (.engineTimeZone, "引擎层时区"), (.disableWebRTC, "关闭 WebRTC"),
                (.safariAPIs, "Safari 专有接口"), (.fontAllowlist, "字体白名单"),
            ]
            protections = named.filter { profile.spi.contains($0.0) }.map(\.1)
            advancedPrivacy = profile.spi.contains(.fingerprintingProtections)
            fontAllowlist = profile.spi.contains(.fontAllowlist)
        }
    }

    static let maxContentWidth: CGFloat = 840
    static let tileSize: CGFloat = 64
    static let tileCornerRadius: CGFloat = 14
    static let tileHeight: CGFloat = 88
    static let cardSize = NSSize(width: 236, height: 140)
    static let bannerHeight: CGFloat = 92
    static let editButtonSize = NSSize(width: 58, height: 26)
    /// 深色 / 无痕环境的背景（近纯黑），浅色是 Safari 起始页的浅灰。
    static let darkBackground = NSColor(srgbRed: 0x0D / 255, green: 0x0D / 255, blue: 0x0F / 255, alpha: 1)
    static let lightBackground = NSColor(srgbRed: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1)
    static let exitIPCheckURL = URL(string: "https://ipcheck.ing")!
    static let claudeURL = URL(string: "https://claude.ai")!

    var onOpenURL: ((URL) -> Void)?
    let store: StartPageStore
    let summary: Summary
    let editButton: NSButton
    private let accent: NSColor
    private let scrollView = NSScrollView()
    private let document = StartPageFlippedView()
    private(set) var tiles: [StartPageTile] = []
    private(set) var cards: [StartPageCard] = []
    private(set) var banner: StartPagePrivacyBanner?
    private(set) var sectionTitles: [StartPageSection: NSTextField] = [:]
    private var favoritesAccessory: NSStackView?
    private(set) var showAllButton: NSButton?
    private(set) var editPopover: NSPopover?
    private(set) var showsAllFavorites = false

    /// `store` 为 nil 时用进程共享的 `StartPageStore.shared`（测试传自己的）。
    init(profile: Profile, accent: NSColor, details: [String], store: StartPageStore? = nil) {
        self.store = store ?? .shared
        self.accent = accent
        summary = Summary(profile: profile, details: details)
        editButton = NSButton(title: "编辑", target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        // 无痕环境和真 Safari 无痕窗口一样，起始页总是深色。
        if summary.isPrivate { appearance = NSAppearance(named: .darkAqua) }

        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        addSubview(scrollView)

        editButton.target = self
        editButton.action = #selector(showEditor(_:))
        editButton.isBordered = false
        editButton.wantsLayer = true
        editButton.layer?.backgroundColor = NSColor.white.cgColor
        editButton.layer?.cornerRadius = Self.editButtonSize.height / 2
        editButton.layer?.borderWidth = 0.5
        editButton.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        editButton.attributedTitle = NSAttributedString(string: "编辑", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black,
        ])
        editButton.setAccessibilityLabel("编辑起始页")
        addSubview(editButton)

        NotificationCenter.default.addObserver(self, selector: #selector(storeDidChange(_:)), name: StartPageStore.didChangeNotification, object: store)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    var usesDarkBackground: Bool {
        summary.isPrivate || effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func updateLayer() {
        layer?.backgroundColor = (usesDarkBackground ? Self.darkBackground : Self.lightBackground).cgColor
    }

    /// 显示时磁贴、卡片、「编辑」都能点；隐藏（或淡出）后一律不接点击，网页照常可点。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        return super.hitTest(point)
    }

    // MARK: 打开网址

    func open(_ url: URL) {
        if let onOpenURL {
            onOpenURL(url)
        } else if let webView = Self.findWebView(near: self) {
            webView.load(URLRequest(url: url))
            window?.makeFirstResponder(webView)
        } else {
            return
        }
        isHidden = true
    }

    /// 起始页叠在网页上面：往上逐层找同一个容器里的 BrowserWebView（跳过起始页自己）。
    static func findWebView(near view: NSView) -> BrowserWebView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let found = firstWebView(in: current, excluding: view) { return found }
            ancestor = current.superview
        }
        return nil
    }

    private static func firstWebView(in root: NSView, excluding: NSView) -> BrowserWebView? {
        for subview in root.subviews where subview !== excluding {
            if let webView = subview as? BrowserWebView { return webView }
            if let webView = firstWebView(in: subview, excluding: excluding) { return webView }
        }
        return nil
    }

    // MARK: 内容

    @objc private func storeDidChange(_ notification: Notification) {
        rebuild()
    }

    /// 按当前设置重建各区块（个人收藏、开关变化时调用）。
    func rebuild() {
        document.subviews.forEach { $0.removeFromSuperview() }
        tiles = []
        cards = []
        banner = nil
        sectionTitles = [:]
        favoritesAccessory = nil
        showAllButton = nil

        if store.isVisible(.favorites) {
            sectionTitles[.favorites] = addSectionTitle("个人收藏")
            let add = Self.headerButton("添加 +", target: self, action: #selector(showEditor(_:)))
            let showAll = Self.headerButton(showsAllFavorites ? "收起 ⌃" : "显示全部 ›", target: self, action: #selector(toggleShowAll(_:)))
            showAllButton = showAll
            let accessory = NSStackView(views: [showAll, add])
            accessory.spacing = 14
            document.addSubview(accessory)
            favoritesAccessory = accessory
            for favorite in store.favorites {
                let tile = StartPageTile(favorite: favorite)
                tile.onOpen = { [weak self] in self?.open(favorite.url) }
                tile.onDelete = { [weak self] in self?.store.removeFavorite(url: favorite.url) }
                tile.onRestoreDefaults = { [weak self] in self?.store.restoreDefaultFavorites() }
                document.addSubview(tile)
                tiles.append(tile)
            }
        }
        if store.isVisible(.suggestions) {
            sectionTitles[.suggestions] = addSectionTitle("建议")
            let environment = StartPageCard(
                icon: .glyph(summary.name.first.map { String($0).uppercased() } ?? "?", accent),
                title: summary.name,
                subtitle: [summary.mode, summary.device].compactMap { $0 }.joined(separator: " · "),
                source: "来自 Safarier 环境护盾 ›"
            )
            let network = StartPageCard(icon: .symbol("network", .systemBlue), title: summary.outbound, subtitle: summary.region, source: "点击检测出口 IP ›")
            network.onClick = { [weak self] in self?.open(Self.exitIPCheckURL) }
            let claude = StartPageCard(
                icon: .symbol("asterisk", NSColor(srgbRed: 0xC9 / 255, green: 0x64 / 255, blue: 0x42 / 255, alpha: 1)),
                title: "Claude", subtitle: "claude.ai · AI 账号快捷入口", source: "前往 claude.ai ›"
            )
            claude.onClick = { [weak self] in self?.open(Self.claudeURL) }
            for card in [environment, network, claude] {
                document.addSubview(card)
                cards.append(card)
            }
        }
        if store.isVisible(.privacyReport) {
            sectionTitles[.privacyReport] = addSectionTitle("隐私报告")
            let report = StartPagePrivacyBanner(summary: summary)
            document.addSubview(report)
            banner = report
        }
        needsLayout = true
    }

    private func addSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 19, weight: .bold)
        label.textColor = .labelColor
        document.addSubview(label)
        return label
    }

    private static func headerButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return button
    }

    /// 个人收藏一行几列：内容够宽是 8 列，窄窗口最少 4 列。
    static func columns(for contentWidth: CGFloat) -> Int {
        max(4, min(8, Int(contentWidth / 92)))
    }

    /// 平时显示两行，「显示全部」后显示全部。
    var visibleFavoriteCount: Int {
        let columns = Self.columns(for: contentWidth(for: scrollView.contentSize.width))
        return showsAllFavorites ? tiles.count : min(tiles.count, columns * 2)
    }

    private func contentWidth(for width: CGFloat) -> CGFloat {
        max(280, min(Self.maxContentWidth, width - 48))
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = scrollView.contentSize.width
        let height = layoutDocument(width: width)
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(height, scrollView.contentSize.height))
        editButton.frame = NSRect(
            x: bounds.maxX - 24 - Self.editButtonSize.width, y: 20,
            width: Self.editButtonSize.width, height: Self.editButtonSize.height
        )
    }

    /// 按宽度排好各区块（文档视图是翻转坐标，从上往下），返回内容高度。
    @discardableResult
    func layoutDocument(width: CGFloat) -> CGFloat {
        let contentWidth = contentWidth(for: width)
        let x0 = ((width - contentWidth) / 2).rounded(.down)
        // 留白照真 Safari 起始页：顶部约 72pt，区块之间约 56pt。
        let sectionGap: CGFloat = 56
        var y: CGFloat = 72

        if let title = sectionTitles[.favorites] {
            title.frame = NSRect(x: x0, y: y, width: contentWidth / 2, height: 26)
            let columns = Self.columns(for: contentWidth)
            let visible = showsAllFavorites ? tiles.count : min(tiles.count, columns * 2)
            showAllButton?.isHidden = tiles.count <= columns * 2
            if let accessory = favoritesAccessory {
                let size = accessory.fittingSize
                accessory.frame = NSRect(x: x0 + contentWidth - size.width, y: y + (26 - size.height) / 2, width: size.width, height: size.height)
            }
            y += 26 + 16
            let cell = (contentWidth / CGFloat(columns)).rounded(.down)
            let rowGap: CGFloat = 18
            for (index, tile) in tiles.enumerated() {
                tile.isHidden = index >= visible
                guard index < visible else { continue }
                let row = index / columns, column = index % columns
                tile.frame = NSRect(x: x0 + CGFloat(column) * cell, y: y + CGFloat(row) * (Self.tileHeight + rowGap), width: cell, height: Self.tileHeight)
            }
            let rows = (visible + columns - 1) / columns
            y += CGFloat(rows) * Self.tileHeight + CGFloat(max(0, rows - 1)) * rowGap + sectionGap
        }

        if let title = sectionTitles[.suggestions] {
            title.frame = NSRect(x: x0, y: y, width: contentWidth, height: 26)
            y += 26 + 16
            let gap: CGFloat = 14
            let cardWidth = min(Self.cardSize.width, ((contentWidth - 2 * gap) / 3).rounded(.down))
            for (index, card) in cards.enumerated() {
                card.frame = NSRect(x: x0 + CGFloat(index) * (cardWidth + gap), y: y, width: cardWidth, height: Self.cardSize.height)
            }
            y += Self.cardSize.height + sectionGap
        }

        if let title = sectionTitles[.privacyReport], let banner {
            title.frame = NSRect(x: x0, y: y, width: contentWidth, height: 26)
            y += 26 + 16
            banner.frame = NSRect(x: x0, y: y, width: contentWidth, height: Self.bannerHeight)
            y += Self.bannerHeight
        }
        // 底部留出「编辑」按钮的位置。
        return y + 80
    }

    // MARK: 动作

    @objc private func toggleShowAll(_ sender: Any?) {
        showsAllFavorites.toggle()
        rebuild()
    }

    /// 「编辑」和「添加 +」：弹出起始页设置（区块开关、添加个人收藏、恢复默认）。
    @objc func showEditor(_ sender: Any?) {
        editPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = StartPageEditor(store: store)
        let anchor = (sender as? NSView) ?? editButton
        if anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor === editButton ? .maxY : .minY)
        }
        editPopover = popover
    }
}

/// 起始页文档视图：翻转坐标，从上往下排。
final class StartPageFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 起始页上的颜色：`#RRGGBB`，解析失败用灰色。
@MainActor
enum StartPageColor {
    static func color(_ hex: String) -> NSColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return .systemGray }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// 卡片底色：深色是半透明白，浅色是白。
    static func cardBackground(dark: Bool) -> NSColor {
        dark ? NSColor.white.withAlphaComponent(0.09) : .white
    }
}

/// 个人收藏的一个磁贴：64×64 连续圆角方块 + 下方标题。点击打开，右键「打开 / 删除此收藏 / 恢复默认收藏」。
@MainActor
final class StartPageTile: NSView {
    let favorite: StartPageFavorite
    let iconView = NSView()
    let titleLabel: NSTextField
    var onOpen: (() -> Void)?
    var onDelete: (() -> Void)?
    var onRestoreDefaults: (() -> Void)?
    private let glyphView: NSView
    private var pressed = false {
        didSet { iconView.alphaValue = pressed ? 0.7 : 1 }
    }

    init(favorite: StartPageFavorite) {
        self.favorite = favorite
        titleLabel = NSTextField(labelWithString: favorite.title)
        let foreground = StartPageColor.color(favorite.foreground)
        if let symbol = favorite.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: favorite.title) {
            let imageView = NSImageView(image: image)
            imageView.symbolConfiguration = .init(pointSize: 28, weight: .semibold)
            imageView.contentTintColor = foreground
            glyphView = imageView
        } else {
            let text = favorite.glyph ?? String(favorite.title.prefix(1)).uppercased()
            let label = NSTextField(labelWithString: text)
            label.alignment = .center
            label.textColor = foreground
            label.font = Self.glyphFont(size: text.count > 2 ? 15 : 30, design: favorite.glyphDesign)
            glyphView = label
        }
        super.init(frame: .zero)
        iconView.wantsLayer = true
        iconView.layer?.backgroundColor = StartPageColor.color(favorite.background).cgColor
        iconView.layer?.cornerRadius = StartPageView.tileCornerRadius
        iconView.layer?.cornerCurve = .continuous
        iconView.layer?.borderWidth = 0.5
        iconView.layer?.borderColor = NSColor.gray.withAlphaComponent(0.25).cgColor
        iconView.addSubview(glyphView)
        addSubview(iconView)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        toolTip = favorite.url.absoluteString
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(favorite.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func glyphFont(size: CGFloat, design: String?) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        let fontDesign: NSFontDescriptor.SystemDesign?
        switch design {
        case "serif": fontDesign = .serif
        case "rounded": fontDesign = .rounded
        default: fontDesign = nil
        }
        guard let fontDesign, let descriptor = base.fontDescriptor.withDesign(fontDesign) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    override func layout() {
        super.layout()
        let size = StartPageView.tileSize
        iconView.frame = NSRect(x: ((bounds.width - size) / 2).rounded(.down), y: 0, width: size, height: size)
        let glyph = glyphView.fittingSize
        glyphView.frame = NSRect(x: (size - glyph.width) / 2, y: (size - glyph.height) / 2, width: glyph.width, height: glyph.height)
        titleLabel.frame = NSRect(x: 2, y: size + 6, width: bounds.width - 4, height: 16)
    }

    /// 整个磁贴（图标和标题）都算一个点击目标。
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onOpen?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("打开", #selector(openFromMenu(_:))), ("删除此收藏", #selector(deleteFromMenu(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let restore = NSMenuItem(title: "恢复默认收藏", action: #selector(restoreFromMenu(_:)), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
        return menu
    }

    @objc private func openFromMenu(_ sender: Any?) { onOpen?() }
    @objc private func deleteFromMenu(_ sender: Any?) { onDelete?() }
    @objc private func restoreFromMenu(_ sender: Any?) { onRestoreDefaults?() }
}

/// 「建议」里的一张卡片：左上角圆角图标框、标题、副标题、底部来源胶囊。
@MainActor
final class StartPageCard: NSView {
    enum Icon {
        case symbol(String, NSColor)
        case glyph(String, NSColor)
    }

    let titleLabel: NSTextField
    let subtitleLabel: NSTextField
    let sourceLabel: NSTextField
    var onClick: (() -> Void)? {
        didSet { setAccessibilityRole(onClick == nil ? .group : .button) }
    }
    private let iconBox = NSView()
    private let iconContent: NSView
    private let capsule = NSView()

    init(icon: Icon, title: String, subtitle: String, source: String) {
        titleLabel = NSTextField(labelWithString: title)
        subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        sourceLabel = NSTextField(labelWithString: source)
        let tint: NSColor
        switch icon {
        case .symbol(let name, let color):
            let imageView = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: title) ?? NSImage())
            imageView.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
            imageView.contentTintColor = .white
            iconContent = imageView
            tint = color
        case .glyph(let text, let color):
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 18, weight: .bold)
            label.textColor = .white
            iconContent = label
            tint = color
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        iconBox.wantsLayer = true
        iconBox.layer?.backgroundColor = tint.cgColor
        iconBox.layer?.cornerRadius = 10
        iconBox.layer?.cornerCurve = .continuous
        iconBox.addSubview(iconContent)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.font = .systemFont(ofSize: 11, weight: .medium)
        sourceLabel.textColor = .secondaryLabelColor
        capsule.wantsLayer = true
        capsule.addSubview(sourceLabel)
        for view in [iconBox, titleLabel, subtitleLabel, capsule] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title)，\(subtitle)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = StartPageColor.cardBackground(dark: dark).cgColor
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)).cgColor
        capsule.layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.06)).cgColor
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 14
        iconBox.frame = NSRect(x: inset, y: inset, width: 40, height: 40)
        let content = iconContent.fittingSize
        iconContent.frame = NSRect(x: (40 - content.width) / 2, y: (40 - content.height) / 2, width: content.width, height: content.height)
        titleLabel.frame = NSRect(x: inset, y: 62, width: bounds.width - 2 * inset, height: 17)
        subtitleLabel.frame = NSRect(x: inset, y: 80, width: bounds.width - 2 * inset, height: 28)
        let text = sourceLabel.fittingSize
        let capsuleWidth = min(bounds.width - 2 * inset, text.width + 16)
        capsule.frame = NSRect(x: inset - 4, y: bounds.height - 10 - 20, width: capsuleWidth, height: 20)
        capsule.layer?.cornerRadius = 10
        sourceLabel.frame = NSRect(x: 8, y: (20 - text.height) / 2, width: capsuleWidth - 16, height: text.height)
    }

    /// 整张卡片一个点击目标；不可点的卡片也接住点击，不漏到下面。
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

/// 「隐私报告」横幅：左边绿色盾牌，右边两块统计（开着的原生保护项、环境隔离状态），按这个环境的实际设置显示。
@MainActor
final class StartPagePrivacyBanner: NSView {
    let protectionValue: NSTextField
    let protectionDetail: NSTextField
    let isolationValue: NSTextField
    let isolationDetail: NSTextField
    private let shield = NSImageView()
    private let leftBox = NSView()
    private let rightBox = NSView()

    init(summary: StartPageView.Summary) {
        protectionValue = NSTextField(labelWithString: "\(summary.protections.count) 项原生保护")
        protectionDetail = NSTextField(wrappingLabelWithString: summary.advancedPrivacy
            ? "Safari 原生防指纹护盾已阻止跨站追踪器剖析此环境"
            : "高级隐私保护没有开启，可以在环境设置里打开")
        isolationValue = NSTextField(labelWithString: summary.isPrivate ? "临时沙盒" : "独立沙盒")
        var isolation = ["独立数据沙盒"]
        if summary.fontAllowlist { isolation.append("字体白名单隔离") }
        if !summary.isDirect { isolation.append("代理断连阻断（Fail-Closed）") }
        isolationDetail = NSTextField(wrappingLabelWithString: isolation.joined(separator: " · "))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        shield.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "隐私保护")
        shield.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
            .applying(.init(paletteColors: [.systemGreen, NSColor.systemGreen.blended(withFraction: 0.45, of: .white) ?? .systemGreen]))
        addSubview(shield)
        for box in [leftBox, rightBox] {
            box.wantsLayer = true
            box.layer?.cornerRadius = 10
            box.layer?.cornerCurve = .continuous
            addSubview(box)
        }
        for (box, value, detail) in [(leftBox, protectionValue, protectionDetail), (rightBox, isolationValue, isolationDetail)] {
            value.font = .systemFont(ofSize: 17, weight: .bold)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.maximumNumberOfLines = 2
            detail.lineBreakMode = .byTruncatingTail
            box.addSubview(value)
            box.addSubview(detail)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("隐私报告：\(protectionValue.stringValue)，\(isolationDetail.stringValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = StartPageColor.cardBackground(dark: dark).cgColor
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)).cgColor
        let boxColor = dark ? NSColor.black.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.05)
        leftBox.layer?.backgroundColor = boxColor.cgColor
        rightBox.layer?.backgroundColor = boxColor.cgColor
    }

    override func layout() {
        super.layout()
        let shieldSize: CGFloat = 44
        shield.frame = NSRect(x: 22, y: (bounds.height - shieldSize) / 2, width: shieldSize, height: shieldSize)
        let left: CGFloat = 22 + shieldSize + 20, gap: CGFloat = 12, inset: CGFloat = 14
        let boxWidth = max(80, (bounds.width - left - gap - inset) / 2)
        let boxHeight = bounds.height - 2 * inset
        for (index, (box, value, detail)) in [(leftBox, protectionValue, protectionDetail), (rightBox, isolationValue, isolationDetail)].enumerated() {
            box.frame = NSRect(x: left + CGFloat(index) * (boxWidth + gap), y: inset, width: boxWidth, height: boxHeight)
            value.frame = NSRect(x: 12, y: box.bounds.height - 10 - 21, width: boxWidth - 24, height: 21)
            detail.frame = NSRect(x: 12, y: 8, width: boxWidth - 24, height: box.bounds.height - 10 - 21 - 8)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }
}

/// 起始页的「编辑」面板：三个区块的开关、添加个人收藏、恢复默认收藏。改动立刻写进 StartPageStore。
@MainActor
final class StartPageEditor: NSViewController {
    let store: StartPageStore
    private(set) var sectionToggles: [StartPageSection: NSButton] = [:]
    let nameField = NSTextField()
    let addressField = NSTextField()
    let messageLabel = NSTextField(labelWithString: "")

    static let sectionTitles: [(StartPageSection, String)] = [(.favorites, "个人收藏"), (.suggestions, "建议"), (.privacyReport, "隐私报告")]

    init(store: StartPageStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let heading = NSTextField(labelWithString: "自定义起始页")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        var rows: [NSView] = [heading]
        for (section, title) in Self.sectionTitles {
            let toggle = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleSection(_:)))
            toggle.state = store.isVisible(section) ? .on : .off
            toggle.identifier = NSUserInterfaceItemIdentifier(section.rawValue)
            sectionToggles[section] = toggle
            rows.append(toggle)
        }
        let separator = NSBox()
        separator.boxType = .separator
        let addHeading = NSTextField(labelWithString: "添加个人收藏")
        addHeading.font = .systemFont(ofSize: 12, weight: .semibold)
        nameField.placeholderString = "网站名称（可不填）"
        addressField.placeholderString = "网址，例如 example.com"
        let add = NSButton(title: "添加", target: self, action: #selector(addFavorite(_:)))
        add.keyEquivalent = "\r"
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        let restore = NSButton(title: "恢复默认收藏", target: self, action: #selector(restoreDefaults(_:)))
        restore.bezelStyle = .inline
        rows += [separator, addHeading, nameField, addressField, add, messageLabel, restore]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        for field in [nameField, addressField] {
            field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        separator.widthAnchor.constraint(equalToConstant: 240).isActive = true
        view = stack
    }

    @objc func toggleSection(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let section = StartPageSection(rawValue: raw) else { return }
        store.setSection(section, visible: sender.state == .on)
    }

    @objc func addFavorite(_ sender: Any?) {
        switch store.addFavorite(title: nameField.stringValue, address: addressField.stringValue) {
        case .success(let favorite):
            messageLabel.textColor = .secondaryLabelColor
            messageLabel.stringValue = "已添加「\(favorite.title)」"
            nameField.stringValue = ""
            addressField.stringValue = ""
        case .failure(.invalidAddress):
            messageLabel.textColor = .systemRed
            messageLabel.stringValue = "网址无效：需要 http / https 网页地址"
        case .failure(.duplicate):
            messageLabel.textColor = .systemRed
            messageLabel.stringValue = "这个网站已经在个人收藏里了"
        }
    }

    @objc func restoreDefaults(_ sender: Any?) {
        store.restoreDefaultFavorites()
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = "已恢复默认收藏"
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
