import AppKit
import SafarierCore

/// 浏览器 ⌘D 添加启动页签时的目标插入位置。
enum StartupTabInsertionPosition: Int, Equatable {
    case append = 0
    case home = 1
}

/// 单次 ⌘D 添加或重新启用的最小撤销令牌，供锁内按 tabID 精准回滚。
enum StartupTabUndoToken: Equatable {
    case added(tabID: UUID)
    case reenabled(tabID: UUID, previousIndex: Int)
}

/// 原子写入启动页签后的结果，用于同步会话首页状态与展示轻反馈。
struct StartupTabSaveResult: Equatable {
    let undoToken: StartupTabUndoToken
    let totalCount: Int
    let wasReenabled: Bool
    let setAsHome: Bool
    let updatedTabs: [StartupTab]
}

/// 浏览器 ⌘D 启动页签确认表单（原生 macOS Safari 风格：紧贴工具栏正下方居中滑出的紧凑模态 Sheet）。
@MainActor
final class AddStartupTabSheetController: NSObject, NSTextFieldDelegate {
    /// 重复检测结果，驱动提示文案与主按钮行为。
    enum DuplicateMatch: Equatable {
        case none
        case enabled(index: Int)
        case paused(tabID: UUID, index: Int)
    }

    static let sheetWidth: CGFloat = 392

    let panel: NSPanel
    let titleLabel: NSTextField
    let subtitleLabel: NSTextField
    let positionPopUp: NSPopUpButton
    let urlField: NSTextField
    let trimQueryButton: NSButton
    let trimOriginButton: NSButton
    let restoreButton: NSButton
    let feedbackLabel: NSTextField
    let cancelButton: NSButton
    let confirmButton: NSButton

    let initialURL: URL?
    private let existingTabs: [StartupTab]
    private var submissionError: String?
    private(set) var duplicateMatch: DuplicateMatch = .none

    /// 提交回调：返回 `.success` 时关闭 Sheet，返回 `.failure` 时保持 Sheet 打开并显示错误。
    var onSubmit: ((URL, StartupTabInsertionPosition, UUID?) -> Result<StartupTabSaveResult, Error>)?
    /// Sheet 关闭后触发：提交成功携带结果，取消则为 nil。
    var onFinished: ((StartupTabSaveResult?) -> Void)?

    private weak var hostWindow: NSWindow?

    init(profileName: String, initialURL: URL?, existingTabs: [StartupTab]) {
        self.initialURL = initialURL
        self.existingTabs = existingTabs

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.sheetWidth, height: 220),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        titleLabel = NSTextField(wrappingLabelWithString: L10n.text("将此页面添加到「%@」启动页签：", profileName))
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        subtitleLabel = NSTextField(wrappingLabelWithString: L10n.text("下次启动该环境时自动打开，不影响当前已打开的标签页。"))
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        positionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        positionPopUp.addItems(withTitles: [
            L10n.text("启动页签末尾（作为第 %lld 项）", existingTabs.count + 1),
            L10n.text("第 1 位 · 设为首页（同步作为 ⇧⌘H）"),
        ])
        positionPopUp.selectItem(at: StartupTabInsertionPosition.append.rawValue)

        urlField = NSTextField(string: initialURL?.absoluteString ?? "")
        urlField.placeholderString = L10n.text("输入或粘贴网址，例如 example.com")
        urlField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        urlField.usesSingleLineMode = true
        urlField.cell?.isScrollable = true
        urlField.cell?.wraps = false

        trimQueryButton = NSButton(title: L10n.text("去掉参数"), target: nil, action: nil)
        trimQueryButton.bezelStyle = .rounded
        trimQueryButton.controlSize = .small
        trimQueryButton.font = .systemFont(ofSize: 11)

        trimOriginButton = NSButton(title: L10n.text("仅保留域名"), target: nil, action: nil)
        trimOriginButton.bezelStyle = .rounded
        trimOriginButton.controlSize = .small
        trimOriginButton.font = .systemFont(ofSize: 11)

        restoreButton = NSButton(title: L10n.text("还原原网址"), target: nil, action: nil)
        restoreButton.isBordered = false
        restoreButton.font = .systemFont(ofSize: 11)
        restoreButton.contentTintColor = .linkColor
        restoreButton.isHidden = true

        feedbackLabel = NSTextField(wrappingLabelWithString: "")
        feedbackLabel.font = .systemFont(ofSize: 11)
        feedbackLabel.textColor = .secondaryLabelColor
        feedbackLabel.isHidden = true

        cancelButton = NSButton(title: L10n.text("取消"), target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        confirmButton = NSButton(title: L10n.text("添加"), target: nil, action: nil)
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"

        super.init()

        urlField.delegate = self
        trimQueryButton.target = self
        trimQueryButton.action = #selector(trimQueryClicked(_:))
        trimOriginButton.target = self
        trimOriginButton.action = #selector(trimOriginClicked(_:))
        restoreButton.target = self
        restoreButton.action = #selector(restoreClicked(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        confirmButton.target = self
        confirmButton.action = #selector(confirmClicked(_:))

        buildLayout()
        refreshValidationState()
    }

    var selectedPosition: StartupTabInsertionPosition {
        StartupTabInsertionPosition(rawValue: positionPopUp.indexOfSelectedItem) ?? .append
    }

    /// 附着在浏览器窗口工具栏正下方弹出，并自动全选网址输入框。
    func present(attachedTo window: NSWindow) {
        hostWindow = window
        resizePanelToFit()
        window.beginSheet(panel) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hostWindow = nil
                let finish = self.onFinished
                self.onFinished = nil
                finish?(nil)
            }
        }
        focusURLField()
    }

    func focusURLField() {
        panel.makeFirstResponder(urlField)
        urlField.selectText(nil)
    }

    /// 供程序化/测试触发：模拟点击「去掉参数」。
    @objc func trimQueryClicked(_ sender: Any?) {
        guard let parsed = AddressInput.webURL(for: urlField.stringValue),
              let trimmed = AddressInput.removingQueryAndFragment(from: parsed) else { return }
        urlField.stringValue = trimmed.absoluteString
        submissionError = nil
        refreshValidationState()
        panel.makeFirstResponder(urlField)
    }

    /// 供程序化/测试触发：模拟点击「仅保留域名」。
    @objc func trimOriginClicked(_ sender: Any?) {
        guard let parsed = AddressInput.webURL(for: urlField.stringValue),
              let origin = AddressInput.originOnly(from: parsed) else { return }
        urlField.stringValue = origin.absoluteString
        submissionError = nil
        refreshValidationState()
        panel.makeFirstResponder(urlField)
    }

    /// 供程序化/测试触发：还原为弹窗打开时的初始网址。
    @objc func restoreClicked(_ sender: Any?) {
        guard let initialURL else { return }
        urlField.stringValue = initialURL.absoluteString
        submissionError = nil
        refreshValidationState()
        focusURLField()
    }

    @objc func cancelClicked(_ sender: Any?) {
        dismiss(result: nil)
    }

    @objc func confirmClicked(_ sender: Any?) {
        guard confirmButton.isEnabled, let parsed = AddressInput.webURL(for: urlField.stringValue) else {
            NSSound.beep()
            return
        }
        let reenableID: UUID?
        if case .paused(let tabID, _) = duplicateMatch {
            reenableID = tabID
        } else {
            reenableID = nil
        }

        guard let onSubmit else {
            dismiss(result: nil)
            return
        }

        switch onSubmit(parsed, selectedPosition, reenableID) {
        case .success(let result):
            dismiss(result: result)
        case .failure(let error):
            submissionError = error.localizedDescription
            refreshValidationState()
        }
    }

    func dismiss(result: StartupTabSaveResult?) {
        let window = hostWindow
        hostWindow = nil
        let finish = onFinished
        onFinished = nil
        if let window, window.attachedSheet === panel {
            window.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
        finish?(result)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        submissionError = nil
        refreshValidationState()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            confirmClicked(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelClicked(nil)
            return true
        default:
            return false
        }
    }

    // MARK: - 校验与布局

    func refreshValidationState() {
        let raw = urlField.stringValue
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        restoreButton.isHidden = initialURL == nil || raw == initialURL?.absoluteString

        guard let parsed = AddressInput.webURL(for: raw) else {
            duplicateMatch = .none
            trimQueryButton.isEnabled = false
            trimOriginButton.isEnabled = false
            confirmButton.isEnabled = false
            confirmButton.title = L10n.text("添加")

            if let submissionError {
                showFeedback(submissionError, color: .systemRed)
            } else if trimmedRaw.isEmpty {
                hideFeedback()
            } else {
                showFeedback(L10n.text("网址格式无效，请输入有效的 http 或 https 网址。"), color: .systemRed)
            }
            resizePanelToFit()
            return
        }

        let withoutQuery = AddressInput.removingQueryAndFragment(from: parsed)
        trimQueryButton.isEnabled = withoutQuery != nil && withoutQuery?.absoluteString != parsed.absoluteString

        let origin = AddressInput.originOnly(from: parsed)
        let originRedundant = origin == nil
            || origin?.absoluteString == parsed.absoluteString
            || (origin.map { AddressInput.isSameStartupURL($0, parsed) } ?? false)
        trimOriginButton.isEnabled = !originRedundant

        duplicateMatch = matchDuplicate(for: parsed)
        confirmButton.isEnabled = true

        if let submissionError {
            showFeedback(submissionError, color: .systemRed)
            updateConfirmTitleForCurrentMatch()
        } else {
            switch duplicateMatch {
            case .enabled(let index):
                showFeedback(
                    L10n.text("提示：此网址已在启动页签中（第 %lld 项），确认将继续追加。", index + 1),
                    color: .systemOrange
                )
                confirmButton.title = L10n.text("仍要添加")
            case .paused(_, let index):
                showFeedback(
                    L10n.text("此网址已存在但处于暂停状态（第 %lld 项），确认后将重新启用。", index + 1),
                    color: .secondaryLabelColor
                )
                confirmButton.title = L10n.text("重新启用")
            case .none:
                confirmButton.title = L10n.text("添加")
                if !trimmedRaw.contains("://") {
                    showFeedback(L10n.text("将自动补全为 %@", parsed.absoluteString), color: .secondaryLabelColor)
                } else {
                    hideFeedback()
                }
            }
        }
        resizePanelToFit()
    }

    private func updateConfirmTitleForCurrentMatch() {
        switch duplicateMatch {
        case .enabled: confirmButton.title = L10n.text("仍要添加")
        case .paused: confirmButton.title = L10n.text("重新启用")
        case .none: confirmButton.title = L10n.text("添加")
        }
    }

    private func matchDuplicate(for url: URL) -> DuplicateMatch {
        // 若已有同网址的启用项，优先提示已启用，避免把另一条暂停项误重新启用成双份。
        if let enabledIndex = existingTabs.firstIndex(where: { $0.isEnabled && AddressInput.isSameStartupURL($0.url, url) }) {
            return .enabled(index: enabledIndex)
        }
        if let pausedIndex = existingTabs.firstIndex(where: { !$0.isEnabled && AddressInput.isSameStartupURL($0.url, url) }) {
            return .paused(tabID: existingTabs[pausedIndex].id, index: pausedIndex)
        }
        return .none
    }

    private func showFeedback(_ text: String, color: NSColor) {
        feedbackLabel.stringValue = text
        feedbackLabel.textColor = color
        feedbackLabel.isHidden = false
    }

    private func hideFeedback() {
        feedbackLabel.stringValue = ""
        feedbackLabel.isHidden = true
    }

    private func buildLayout() {
        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 3

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let trimRow = NSStackView(views: [trimQueryButton, trimOriginButton, spacer, restoreButton])
        trimRow.orientation = .horizontal
        trimRow.alignment = .centerY
        trimRow.spacing = 6

        let urlStack = NSStackView(views: [urlField, trimRow, feedbackLabel])
        urlStack.orientation = .vertical
        urlStack.alignment = .leading
        urlStack.spacing = 6

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [buttonSpacer, cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let rootStack = NSStackView(views: [headerStack, positionPopUp, urlStack, buttonRow])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        rootStack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: Self.sheetWidth, height: 220))
        contentView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            contentView.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
            headerStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40),
            positionPopUp.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40),
            urlStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40),
            urlField.widthAnchor.constraint(equalTo: urlStack.widthAnchor),
            trimRow.widthAnchor.constraint(equalTo: urlStack.widthAnchor),
            feedbackLabel.widthAnchor.constraint(equalTo: urlStack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40),
        ])
        panel.contentView = contentView
        resizePanelToFit()
    }

    private func resizePanelToFit() {
        guard let contentView = panel.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let fitting = contentView.fittingSize
        let size = NSSize(width: Self.sheetWidth, height: max(160, fitting.height))
        if abs(panel.contentLayoutRect.height - size.height) > 0.5 || abs(panel.contentLayoutRect.width - size.width) > 0.5 {
            panel.setContentSize(size)
        }
    }
}

/// 浏览器窗口底部居中展示的轻量悬浮提示条（保存启动页签后自动淡出，支持一键撤销）。
@MainActor
final class StartupTabToastView: NSVisualEffectView {
    let messageLabel = NSTextField(labelWithString: "")
    let undoButton = NSButton(title: L10n.text("撤销"), target: nil, action: nil)
    var onUndo: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        messageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        messageLabel.textColor = .labelColor

        undoButton.isBordered = false
        undoButton.font = .systemFont(ofSize: 12, weight: .semibold)
        undoButton.contentTintColor = .linkColor
        undoButton.target = self
        undoButton.action = #selector(undoClicked(_:))

        let stack = NSStackView(views: [messageLabel, undoButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(message: String, allowsUndo: Bool) {
        messageLabel.stringValue = message
        undoButton.isHidden = !allowsUndo
    }

    @objc func undoClicked(_ sender: Any?) {
        onUndo?()
    }
}
