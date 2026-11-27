import AppKit
import SwiftUI
import SafarierCore

/// 输入未通过校验时只留在草稿中，不把无效网址写入环境。
struct StartupTabDraft: Equatable, Identifiable {
    var id: UUID = UUID()
    var url: String = ""
    var isEnabled = true

    init(id: UUID = UUID(), url: String = "", isEnabled: Bool = true) {
        self.id = id
        self.url = url
        self.isEnabled = isEnabled
    }

    init(_ tab: StartupTab) {
        self.init(id: tab.id, url: tab.url.absoluteString, isEnabled: tab.isEnabled)
    }

    var webURL: URL? { AddressInput.webURL(for: url) }

    func validatedTab(at index: Int) throws -> StartupTab {
        guard let webURL else {
            throw ProfileEditorError.invalid(L10n.text("第 %lld 个启动页签的网址无效，请输入 http 或 https 网址，或删除该项。", index + 1))
        }
        return StartupTab(id: id, url: webURL, isEnabled: isEnabled)
    }
}

/// 新建和详情表单共用的启动页签列表。
struct StartupTabsSection: View {
    struct DeletedTabSnapshot: Equatable {
        let tab: StartupTabDraft
        let index: Int
        let remainingIDs: [UUID]
    }

    @Binding var tabs: [StartupTabDraft]
    var showsAllValidationErrors = false

    @FocusState private var focusedTabID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var touchedIDs: Set<UUID> = []
    @State private var pendingNewTabIDs: Set<UUID> = []
    @State private var deletedSnapshot: DeletedTabSnapshot?
    @State private var undoDismissTask: Task<Void, Never>?
    @State private var outsideClickMonitor: Any?
    @State private var lastInternalActionAt: CFAbsoluteTime = 0

    var body: some View {
        let firstEnabledID = Self.firstEnabledID(in: tabs)
        let enabledCount = tabs.filter(\.isEnabled).count

        Section {
            if tabs.isEmpty {
                emptyStateView
            } else {
                // 不使用 ForEach($tabs)：macOS 上删除聚焦的末行时，NSTextField 会在结束编辑阶段
                // 回读旧的下标绑定，导致 Array._checkSubscript 越界崩溃；这里统一改用按 UUID 查找的安全绑定。
                ForEach(tabs) { tab in
                    let index = tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
                    let order = Self.enabledOrder(of: tab.id, in: tabs)
                    let isHome = tab.id == firstEnabledID
                    let showError = Self.shouldShowInlineError(
                        tab: tab,
                        focusedID: focusedTabID,
                        touchedIDs: touchedIDs,
                        pendingIDs: pendingNewTabIDs,
                        showsAll: showsAllValidationErrors
                    )
                    StartupTabRow(
                        tab: tab,
                        url: Self.urlBinding(for: tab.id, fallback: tab.url, in: $tabs),
                        isEnabled: Self.enabledBinding(for: tab.id, fallback: tab.isEnabled, in: $tabs),
                        index: index,
                        totalCount: tabs.count,
                        enabledOrder: order,
                        isHome: isHome,
                        showsError: showError,
                        focusedTabID: $focusedTabID,
                        reduceMotion: reduceMotion,
                        onSubmit: { handleSubmit(for: tab.id) },
                        onCancelEdit: { resignActiveTextField() },
                        onMove: { offset in animateChange { Self.move(&tabs, id: tab.id, by: offset) } },
                        onMoveToTop: { animateChange { Self.moveToTop(&tabs, id: tab.id) } },
                        onReorderFrom: { draggedID in
                            animateChange { Self.reorder(&tabs, moving: draggedID, to: tab.id) }
                        },
                        onDelete: { deleteTab(tab.id) }
                    )
                }
                addFooterRow
            }
        } header: {
            HStack(spacing: 8) {
                Text("启动页签")
                Spacer()
                headerStatusBadge(enabledCount: enabledCount, totalCount: tabs.count)
            }
        } footer: {
            Text("启动时按顺序打开已启用的网址，第 1 个启用项同时作为主页（⇧⌘H）。修改在下次启动时生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: focusedTabID) { previous, current in
            updateOutsideClickMonitor(active: current != nil)
            guard let previous else { return }
            animateChange {
                Self.handleBlur(&tabs, pendingIDs: &pendingNewTabIDs, touchedIDs: &touchedIDs, blurredID: previous)
            }
        }
        .onChange(of: tabs.map(\.id)) { _, currentIDs in
            let validIDs = Set(currentIDs)
            touchedIDs.formIntersection(validIDs)
            pendingNewTabIDs.formIntersection(validIDs)
            if let snapshot = deletedSnapshot, currentIDs != snapshot.remainingIDs {
                clearUndoSnapshot()
            }
        }
        .onDisappear {
            stopOutsideClickMonitor()
            undoDismissTask?.cancel()
            undoDismissTask = nil
            Self.discardAllEmptyPending(&tabs, pendingIDs: &pendingNewTabIDs)
        }
    }

    // MARK: - 子视图

    @ViewBuilder
    private func headerStatusBadge(enabledCount: Int, totalCount: Int) -> some View {
        if totalCount == 0 {
            EmptyView()
        } else if enabledCount == 0 {
            Text(L10n.text("全部已暂停（共 %lld 个）", totalCount))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(.orange)
                .background(Capsule().fill(Color.orange.opacity(0.14)))
        } else {
            Text(L10n.text("%lld / %lld 已启用", enabledCount, totalCount))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(.secondary)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
                .accessibilityHidden(true)
            VStack(spacing: 3) {
                Text("未配置启动页签")
                    .font(.callout.weight(.medium))
                Text("启动时默认打开起始页，可按顺序添加多个常用网址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                Button { addTab() } label: {
                    Label("添加启动页签", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if deletedSnapshot != nil {
                    Button("撤销删除") { undoDelete() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var addFooterRow: some View {
        HStack(spacing: 10) {
            Button { addTab() } label: {
                Label("添加启动页签", systemImage: "plus")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            if deletedSnapshot != nil {
                HStack(spacing: 6) {
                    Text("已删除 1 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("撤销") { undoDelete() }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .transition(.opacity)
            } else {
                Text("按回车可连续添加")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 交互操作

    private func addTab() {
        lastInternalActionAt = CFAbsoluteTimeGetCurrent()
        clearUndoSnapshot()
        var targetID: UUID?
        animateChange {
            targetID = Self.prepareAddTab(&tabs, pendingIDs: &pendingNewTabIDs)
        }
        if let targetID {
            Task { @MainActor in
                focusedTabID = targetID
            }
        }
    }

    private func deleteTab(_ id: UUID) {
        lastInternalActionAt = CFAbsoluteTimeGetCurrent()
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = tabs[index]
        let isEmptyPending = pendingNewTabIDs.remove(id) != nil
            && removed.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if focusedTabID == id {
            focusedTabID = nil
            if let window = NSApp.keyWindow, window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
            }
        }
        animateChange {
            if let currentIndex = tabs.firstIndex(where: { $0.id == id }) {
                tabs.remove(at: currentIndex)
                if !isEmptyPending {
                    deletedSnapshot = DeletedTabSnapshot(tab: removed, index: currentIndex, remainingIDs: tabs.map(\.id))
                }
            }
        }
        touchedIDs.remove(id)
        if !isEmptyPending {
            scheduleUndoDismiss()
        }
    }

    private func resignActiveTextField() {
        focusedTabID = nil
        if let window = NSApp.keyWindow, window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        }
    }

    private func updateOutsideClickMonitor(active: Bool) {
        guard active else {
            stopOutsideClickMonitor()
            return
        }
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            guard let window = event.window, window === NSApp.keyWindow else { return event }
            guard let editorView = window.firstResponder as? NSTextView else { return event }
            let activeField = (editorView.delegate as? NSView) ?? editorView
            let hitView = window.contentView?.hitTest(event.locationInWindow)
            guard Self.shouldResignFocusOnClick(
                activeField: activeField,
                fieldEditor: editorView,
                hitView: hitView
            ) else {
                return event
            }
            DispatchQueue.main.async {
                guard CFAbsoluteTimeGetCurrent() - lastInternalActionAt > 0.15 else { return }
                guard window.firstResponder === editorView else { return }
                window.makeFirstResponder(nil)
                focusedTabID = nil
            }
            return event
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func undoDelete() {
        guard let snapshot = deletedSnapshot else { return }
        clearUndoSnapshot()
        var restored = false
        animateChange { restored = Self.restoreDeleted(&tabs, from: snapshot) }
        if restored, snapshot.tab.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedTabID = snapshot.tab.id
        }
    }

    private func scheduleUndoDismiss() {
        undoDismissTask?.cancel()
        undoDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            animateChange { deletedSnapshot = nil }
        }
    }

    private func clearUndoSnapshot() {
        undoDismissTask?.cancel()
        undoDismissTask = nil
        deletedSnapshot = nil
    }

    private func handleSubmit(for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = tabs[index].url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, pendingNewTabIDs.contains(id) {
            focusedTabID = nil
            return
        }
        pendingNewTabIDs.remove(id)
        touchedIDs.insert(id)
        if index < tabs.count - 1 {
            focusedTabID = tabs[index + 1].id
        } else if tabs[index].webURL != nil {
            addTab()
        } else {
            focusedTabID = nil
        }
    }

    private func animateChange(_ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(.snappy(duration: 0.2), updates)
        }
    }

    // MARK: - 纯逻辑辅助（便于单元测试）

    static func firstEnabledID(in tabs: [StartupTabDraft]) -> UUID? {
        tabs.first(where: \.isEnabled)?.id
    }

    static func enabledOrder(of id: UUID, in tabs: [StartupTabDraft]) -> Int? {
        var order = 0
        for tab in tabs {
            if tab.isEnabled { order += 1 }
            if tab.id == id { return tab.isEnabled ? order : nil }
        }
        return nil
    }

    static func move(_ tabs: inout [StartupTabDraft], id: UUID, by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              tabs.indices.contains(index + offset) else { return }
        tabs.swapAt(index, index + offset)
    }

    static func moveToTop(_ tabs: inout [StartupTabDraft], id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var item = tabs.remove(at: index)
        item.isEnabled = true
        tabs.insert(item, at: 0)
    }

    static func reorder(_ tabs: inout [StartupTabDraft], moving sourceID: UUID, to targetID: UUID) {
        guard sourceID != targetID,
              let fromIndex = tabs.firstIndex(where: { $0.id == sourceID }),
              let toIndex = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        let item = tabs.remove(at: fromIndex)
        tabs.insert(item, at: toIndex)
    }

    /// 撤销删除：若该标识已重新存在（例如刚点击过还原），拒绝重复插入。
    @discardableResult
    static func restoreDeleted(_ tabs: inout [StartupTabDraft], from snapshot: DeletedTabSnapshot) -> Bool {
        guard !tabs.contains(where: { $0.id == snapshot.tab.id }) else { return false }
        let insertIndex = min(max(0, snapshot.index), tabs.count)
        tabs.insert(snapshot.tab, at: insertIndex)
        return true
    }

    /// 若已有未填写的新增空白行则直接复用，避免连续点添加堆出多条空行。
    static func prepareAddTab(_ tabs: inout [StartupTabDraft], pendingIDs: inout Set<UUID>) -> UUID {
        if let existing = tabs.first(where: {
            pendingIDs.contains($0.id) && $0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return existing.id
        }
        let tab = StartupTabDraft()
        tabs.append(tab)
        pendingIDs.insert(tab.id)
        return tab.id
    }

    /// 新增的空白页签失焦且未填写地址时自动撤销新增，形成闭环；已填内容的项转为正式行并记录失焦校验状态。
    @discardableResult
    static func handleBlur(
        _ tabs: inout [StartupTabDraft],
        pendingIDs: inout Set<UUID>,
        touchedIDs: inout Set<UUID>,
        blurredID: UUID
    ) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == blurredID }) else {
            pendingIDs.remove(blurredID)
            return false
        }
        let trimmed = tabs[index].url.trimmingCharacters(in: .whitespacesAndNewlines)
        if pendingIDs.remove(blurredID) != nil, trimmed.isEmpty {
            tabs.remove(at: index)
            touchedIDs.remove(blurredID)
            return true
        }
        touchedIDs.insert(blurredID)
        return false
    }

    /// 页面离开时兜底清理未填写的新增空白行，避免留下无效草稿。
    static func discardAllEmptyPending(_ tabs: inout [StartupTabDraft], pendingIDs: inout Set<UUID>) {
        guard !pendingIDs.isEmpty else { return }
        tabs.removeAll { tab in
            pendingIDs.contains(tab.id) && tab.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        pendingIDs.removeAll()
    }

    /// 按 UUID 构造安全网址绑定：即便某行刚被删除而 NSTextField 仍在结束编辑，也绝不发生下标越界。
    static func urlBinding(for id: UUID, fallback: String, in tabs: Binding<[StartupTabDraft]>) -> Binding<String> {
        Binding(
            get: { tabs.wrappedValue.first(where: { $0.id == id })?.url ?? fallback },
            set: { newValue in
                guard let index = tabs.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
                tabs.wrappedValue[index].url = newValue
            }
        )
    }

    /// 按 UUID 构造安全开关绑定，避免删除行后残留控件回调越界。
    static func enabledBinding(for id: UUID, fallback: Bool, in tabs: Binding<[StartupTabDraft]>) -> Binding<Bool> {
        Binding(
            get: { tabs.wrappedValue.first(where: { $0.id == id })?.isEnabled ?? fallback },
            set: { newValue in
                guard let index = tabs.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
                tabs.wrappedValue[index].isEnabled = newValue
            }
        )
    }

    /// 点击位置不在当前编辑框且不是另一个可编辑输入框时，主动结束编辑以触发失焦闭环。
    @MainActor
    static func shouldResignFocusOnClick(activeField: NSView, fieldEditor: NSView, hitView: NSView?) -> Bool {
        guard let hitView else { return true }
        if hitView === activeField || hitView.isDescendant(of: activeField) { return false }
        if hitView === fieldEditor || hitView.isDescendant(of: fieldEditor) { return false }
        var cursor: NSView? = hitView
        while let view = cursor {
            if let textField = view as? NSTextField, textField.isEditable { return false }
            if let textView = view as? NSTextView, textView.isEditable { return false }
            cursor = view.superview
        }
        return true
    }

    /// 失焦后才提示无效输入；触发提交校验时同时标出空行与无效行。
    static func shouldShowInlineError(
        tab: StartupTabDraft,
        focusedID: UUID?,
        touchedIDs: Set<UUID>,
        pendingIDs: Set<UUID> = [],
        showsAll: Bool
    ) -> Bool {
        guard tab.webURL == nil else { return false }
        if showsAll { return true }
        guard focusedID != tab.id, touchedIDs.contains(tab.id) else { return false }
        return !pendingIDs.contains(tab.id)
    }
}

/// 单行启动页签：左侧拖拽排序/序号 + 融入式网址输入 + 迷你拨动开关 + 右侧悬停删除。
private struct StartupTabRow: View {
    let tab: StartupTabDraft
    let url: Binding<String>
    let isEnabled: Binding<Bool>
    let index: Int
    let totalCount: Int
    let enabledOrder: Int?
    let isHome: Bool
    let showsError: Bool
    var focusedTabID: FocusState<UUID?>.Binding
    let reduceMotion: Bool
    let onSubmit: () -> Void
    let onCancelEdit: () -> Void
    let onMove: (Int) -> Void
    let onMoveToTop: () -> Void
    let onReorderFrom: (UUID) -> Void
    let onDelete: () -> Void

    private enum ControlFocus: Hashable {
        case toggle
        case delete
    }

    @State private var isHovered = false
    @State private var isDeleteHovered = false
    @State private var isDropTargeted = false
    @FocusState private var controlFocus: ControlFocus?

    private var isFocused: Bool { focusedTabID.wrappedValue == tab.id }
    private var showsDelete: Bool { isHovered || isFocused || controlFocus != nil || isDropTargeted }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                leadingHandleAndBadge
                urlInputField
                Toggle("启动时打开", isOn: isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .fixedSize()
                    .focused($controlFocus, equals: .toggle)
                    .help(tab.isEnabled
                        ? L10n.text("关闭开关可暂停此页签的自动启动")
                        : L10n.text("开启开关以恢复此页签的自动启动"))
                    .accessibilityLabel(Text(L10n.text("启动时打开第 %lld 个页签", index + 1)))
                deleteButton
            }

            if showsError {
                Text(tab.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? L10n.text("请输入网址，或删除此空白行。")
                    : L10n.text("请输入有效的 http 或 https 网址。"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, totalCount > 1 ? 46 : 30)
            }
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isDropTargeted ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeInOut(duration: 0.14)) { isHovered = hovering }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let draggedID = UUID(uuidString: raw), draggedID != tab.id else {
                return false
            }
            onReorderFrom(draggedID)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .contextMenu {
            Button("设为首个（主页）") { onMoveToTop() }
                .disabled(index == 0 && tab.isEnabled)
            Button("上移") { onMove(-1) }
                .disabled(index == 0)
            Button("下移") { onMove(1) }
                .disabled(index == totalCount - 1)
            Divider()
            Button(tab.isEnabled ? L10n.text("暂停此页签") : L10n.text("启用此页签")) {
                isEnabled.wrappedValue.toggle()
            }
            Button("删除页签", role: .destructive) { onDelete() }
        }
    }

    @ViewBuilder
    private var leadingHandleAndBadge: some View {
        let content = HStack(spacing: 6) {
            if totalCount > 1 {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 0.8 : 0.3)
                    .frame(width: 12)
                    .help("拖拽调整打开顺序")
                    .accessibilityHidden(true)
            }
            orderBadge
        }

        if totalCount > 1 {
            content.draggable(tab.id.uuidString)
        } else {
            content
        }
    }

    @ViewBuilder
    private var orderBadge: some View {
        if let enabledOrder {
            Text(verbatim: "\(enabledOrder)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isHome ? Color.accentColor : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHome ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.07))
                )
                .help(isHome
                    ? L10n.text("启动时自动聚焦，并作为主页（⇧⌘H）")
                    : L10n.text("启动打开顺序第 %lld 位", enabledOrder))
        } else {
            Image(systemName: "pause.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .opacity(0.75)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
                .help("已暂停，启动时跳过")
                .accessibilityHidden(true)
        }
    }

    private var urlInputField: some View {
        HStack(spacing: 6) {
            Image(systemName: showsError ? "exclamationmark.circle.fill" : "globe")
                .font(.system(size: 12))
                .foregroundStyle(showsError ? .red : .secondary)
                .opacity(!tab.isEnabled && !showsError ? 0.5 : 1)
                .accessibilityHidden(true)

            TextField("网址", text: url, prompt: Text("https://example.com"))
                .textFieldStyle(.plain)
                .labelsHidden()
                .autocorrectionDisabled()
                .focused(focusedTabID, equals: tab.id)
                .foregroundStyle(tab.isEnabled ? .primary : .secondary)
                .opacity(tab.isEnabled ? 1 : 0.78)
                .onSubmit(onSubmit)
                .onExitCommand(perform: onCancelEdit)
                .accessibilityLabel(Text(L10n.text("第 %lld 个启动页签的网址", index + 1)))

            if isHome {
                Text("主页")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(Color.accentColor)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .help("启动时自动聚焦，并作为主页（⇧⌘H）")
            } else if !tab.isEnabled {
                Text("已暂停")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(.secondary)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(urlFieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(urlFieldBorder, lineWidth: 1)
        )
    }

    private var urlFieldBackground: Color {
        if showsError { return Color.red.opacity(0.05) }
        if isFocused { return Color.primary.opacity(0.04) }
        if isHovered { return Color.primary.opacity(0.03) }
        return .clear
    }

    private var urlFieldBorder: Color {
        if showsError { return Color.red.opacity(0.75) }
        if isFocused { return Color.accentColor.opacity(0.6) }
        return .clear
    }

    private var deleteButton: some View {
        Button(role: .destructive) { onDelete() } label: {
            Label("删除页签", systemImage: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isDeleteHovered ? .red : .secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isDeleteHovered ? Color.red.opacity(0.12) : .clear)
                )
                .contentShape(Rectangle())
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .focused($controlFocus, equals: .delete)
        .help("删除页签")
        .onHover { isDeleteHovered = $0 }
        .opacity(showsDelete ? 1 : 0)
        .allowsHitTesting(showsDelete)
    }
}
