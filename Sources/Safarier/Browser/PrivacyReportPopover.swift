import AppKit
import SafarierCore

/// 地址栏左侧「隐私报告」盾牌按钮弹出的面板，样式和结构对标真 Safari 的隐私报告小弹窗。
@MainActor
enum PrivacyReportPopover {
    static let popoverWidth: CGFloat = 340

    struct ProtectionItem: Equatable, Sendable {
        let title: String
        let detail: String
        let isActive: Bool
    }

    static func siteSubtitle(for currentURL: URL?) -> String {
        if let url = currentURL,
           let scheme = url.scheme?.lowercased(),
           scheme != "about",
           let host = url.host,
           !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return "当前环境隐私护盾已就绪"
    }

    static func protectionItems(
        profile: Profile,
        report: PrivacyCapabilityReport,
        outboundDescription: String
    ) -> [ProtectionItem] {
        let afpActive: Bool = {
            if case .active = report[.advancedPrivacyProtections] { return true }
            return profile.spi.contains(.fingerprintingProtections)
        }()
        let sandboxDetail = profile.mode == .ephemeral
            ? "临时无痕 · 关闭窗口即销毁全部网站数据"
            : "持久隔离 · 当前环境独立 Cookie 与存储沙盒"
        let outboundText = outboundDescription.isEmpty ? "直连" : outboundDescription
        let proxyDetail = outboundText == "直连"
            ? "\(outboundText) · Fail-Closed 零泄漏保护待命"
            : "\(outboundText) · Fail-Closed 零泄漏保护已启用"
        let localeSummary: String = {
            let lang = profile.languages.isEmpty ? "跟随系统语言" : profile.languages.joined(separator: ", ")
            let tz = profile.timeZoneIdentifier ?? "跟随系统时区"
            return "系统字体白名单隔离 · \(lang) · \(tz)"
        }()

        return [
            ProtectionItem(
                title: "Safari 原生防指纹保护",
                detail: afpActive ? "Canvas / WebGL / Audio 动态噪声已启用" : "Canvas / WebGL / Audio 动态噪声（标准模式）",
                isActive: true
            ),
            ProtectionItem(
                title: "独立网站数据沙盒",
                detail: sandboxDetail,
                isActive: true
            ),
            ProtectionItem(
                title: "出站代理通道",
                detail: proxyDetail,
                isActive: true
            ),
            ProtectionItem(
                title: "系统字体白名单隔离 & 区域时区引擎同步",
                detail: localeSummary,
                isActive: true
            ),
        ]
    }

    static func makeViewController(
        profile: Profile,
        currentURL: URL?,
        report: PrivacyCapabilityReport,
        outboundDescription: String
    ) -> NSViewController {
        let controller = PopoverViewController()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        // 顶部：绿色盾牌图标 + 标题「隐私报告」+ 当前网站域名（起始页显示「当前环境隐私护盾已就绪」）
        let shieldIcon = NSImageView()
        shieldIcon.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "隐私报告")
        shieldIcon.symbolConfiguration = .init(pointSize: 22, weight: .semibold)
        shieldIcon.contentTintColor = .systemGreen
        shieldIcon.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: "隐私报告")
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.textColor = .labelColor

        let subtitleLabel = NSTextField(labelWithString: siteSubtitle(for: currentURL))
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let headerRow = NSStackView(views: [shieldIcon, titleStack])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        root.addArrangedSubview(headerRow)

        // 中部卡片：显示当前环境（profile.name）已生效的原生保护项列表
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 8
        cardStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        cardStack.translatesAutoresizingMaskIntoConstraints = false

        let profileHeader = NSTextField(labelWithString: "当前环境：\(profile.name)")
        profileHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        profileHeader.textColor = .secondaryLabelColor
        cardStack.addArrangedSubview(profileHeader)

        for item in protectionItems(profile: profile, report: report, outboundDescription: outboundDescription) {
            cardStack.addArrangedSubview(makeProtectionRow(item))
        }

        card.addSubview(cardStack)
        let innerWidth = popoverWidth - 28
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: innerWidth),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        root.addArrangedSubview(card)

        // 底部：「拷贝环境诊断摘要」快捷按钮
        let copyButton = NSButton(
            title: "拷贝环境诊断摘要",
            target: controller,
            action: #selector(PopoverViewController.copyDiagnosticsButtonClicked(_:))
        )
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .regular
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "拷贝环境诊断摘要")
        copyButton.imagePosition = .imageLeading
        root.addArrangedSubview(copyButton)

        root.layoutSubtreeIfNeeded()
        let fittingHeight = max(220, root.fittingSize.height)
        root.frame = NSRect(x: 0, y: 0, width: popoverWidth, height: fittingHeight)
        controller.view = root
        controller.preferredContentSize = NSSize(width: popoverWidth, height: fittingHeight)
        return controller
    }

    private static func makeProtectionRow(_ item: ProtectionItem) -> NSView {
        let checkIcon = NSImageView()
        checkIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "已生效")
        checkIcon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        checkIcon.contentTintColor = .systemGreen
        checkIcon.setContentHuggingPriority(.required, for: .horizontal)

        let titleField = NSTextField(labelWithString: item.title)
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = .labelColor

        let detailField = NSTextField(wrappingLabelWithString: item.detail)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleField, detailField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let row = NSStackView(views: [checkIcon, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        return row
    }
}

@MainActor
private final class PopoverViewController: NSViewController {
    @objc func copyDiagnosticsButtonClicked(_ sender: Any?) {
        NSApp.sendAction(#selector(BrowserActions.copyDiagnostics(_:)), to: nil, from: sender)
    }
}
