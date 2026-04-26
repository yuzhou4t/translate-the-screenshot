import AppKit
import SwiftUI

@MainActor
final class FloatingTranslatePanel {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<FloatingTranslateView>?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private let favoriteStore: FavoriteStore
    private let translationService: TranslationService
    private let normalPanelSize = NSSize(width: 560, height: 560)
    private let comparisonPanelSize = NSSize(width: 800, height: 600)
    private var currentPresentationID: UUID?
    private var dismissedPresentationID: UUID?
    private var currentSourceText: String?
    private var isPinned = false

    init(favoriteStore: FavoriteStore, translationService: TranslationService) {
        self.favoriteStore = favoriteStore
        self.translationService = translationService
    }

    @discardableResult
    func showLoading(sourceText: String?, near point: NSPoint) -> UUID {
        let presentationID = UUID()
        currentPresentationID = presentationID
        dismissedPresentationID = nil
        currentSourceText = sourceText
        isPinned = false
        show(state: .loading(sourceText: sourceText), near: point, shouldReposition: true)
        return presentationID
    }

    func updateLoading(sourceText: String?, near point: NSPoint, presentationID: UUID) {
        guard canUpdatePresentation(presentationID) else {
            return
        }

        currentSourceText = sourceText
        show(state: .loading(sourceText: sourceText), near: point, shouldReposition: false)
    }

    func showResult(item: TranslationHistoryItem, near point: NSPoint, presentationID: UUID) {
        guard canUpdatePresentation(presentationID) else {
            return
        }

        currentSourceText = item.sourceText
        show(state: .result(item), near: point, shouldReposition: false)
    }

    func showError(_ message: String, near point: NSPoint, presentationID: UUID) {
        guard canUpdatePresentation(presentationID) else {
            return
        }

        show(state: .error(message, sourceText: currentSourceText), near: point, shouldReposition: false)
    }

    private func canUpdatePresentation(_ presentationID: UUID) -> Bool {
        currentPresentationID == presentationID &&
            dismissedPresentationID != presentationID &&
            panel?.isVisible == true
    }

    private func show(state: FloatingTranslateState, near point: NSPoint, shouldReposition: Bool) {
        let contentView = FloatingTranslateView(
            state: state,
            favoriteStore: favoriteStore,
            onRetranslate: retranslate(_:using:),
            onComparisonLayoutChange: setComparisonExpanded(_:),
            onPinnedChange: setPinned(_:),
            onCopyText: copyToPasteboard(_:),
            onClose: hide
        )

        if panel == nil {
            let newPanel = NSPanel(
                contentRect: NSRect(origin: .zero, size: normalPanelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.level = .floating
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            newPanel.hidesOnDeactivate = false
            newPanel.isReleasedWhenClosed = false
            newPanel.isMovableByWindowBackground = true
            panel = newPanel
        }

        if let hostingController {
            hostingController.rootView = contentView
        } else {
            let controller = NSHostingController(rootView: contentView)
            hostingController = controller
            panel?.contentViewController = controller
        }

        if shouldReposition {
            panel?.setFrame(NSRect(origin: origin(for: point, size: normalPanelSize), size: normalPanelSize), display: true)
        }
        panel?.orderFrontRegardless()
        installDismissMonitorsIfNeeded()
    }

    func hide() {
        dismissedPresentationID = currentPresentationID
        panel?.orderOut(nil)
        removeDismissMonitors()
    }

    private func installDismissMonitorsIfNeeded() {
        guard localMouseDownMonitor == nil, globalMouseDownMonitor == nil else {
            return
        }

        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor in
                self?.hideIfClickIsOutsidePanel()
            }
            return event
        }

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor in
                self?.hideIfClickIsOutsidePanel()
            }
        }
    }

    private func removeDismissMonitors() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }

        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
    }

    private func hideIfClickIsOutsidePanel() {
        guard let panel, panel.isVisible else {
            removeDismissMonitors()
            return
        }

        guard !isPinned else {
            return
        }

        if !panel.frame.contains(NSEvent.mouseLocation) {
            hide()
        }
    }

    private func origin(for point: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { screen in
            screen.frame.contains(point)
        } ?? NSScreen.main

        guard let visibleFrame = screen?.visibleFrame else {
            return NSPoint(x: point.x + 12, y: point.y - size.height - 12)
        }

        let preferred = NSPoint(x: point.x + 14, y: point.y - size.height - 14)
        let x = min(max(preferred.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        let y = min(max(preferred.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }

    private func retranslate(
        _ item: TranslationHistoryItem,
        using translationMode: TranslationMode
    ) async throws -> TranslationHistoryItem {
        try await translationService.translate(
            text: item.sourceText,
            sourceLanguage: item.sourceLanguage,
            targetLanguage: item.targetLanguage,
            translationMode: translationMode,
            mode: item.mode
        )
    }

    private func setComparisonExpanded(_ isExpanded: Bool) {
        guard let panel, panel.isVisible else {
            return
        }

        let targetSize = isExpanded ? comparisonPanelSize : normalPanelSize
        panel.setFrame(resizedFrame(from: panel.frame, to: targetSize), display: true, animate: true)
    }

    private func resizedFrame(from frame: NSRect, to size: NSSize) -> NSRect {
        let visibleFrame = panel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let preferredOrigin = NSPoint(x: frame.minX, y: frame.maxY - size.height)

        guard let visibleFrame else {
            return NSRect(origin: preferredOrigin, size: size)
        }

        let x = min(max(preferredOrigin.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        let y = min(max(preferredOrigin.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func setPinned(_ isPinned: Bool) {
        self.isPinned = isPinned
    }
}

enum FloatingTranslateState: Equatable {
    case loading(sourceText: String?)
    case result(TranslationHistoryItem)
    case error(String, sourceText: String?)
}

struct FloatingTranslateView: View {
    var state: FloatingTranslateState
    var favoriteStore: FavoriteStore
    var onRetranslate: (TranslationHistoryItem, TranslationMode) async throws -> TranslationHistoryItem
    var onComparisonLayoutChange: (Bool) -> Void
    var onPinnedChange: (Bool) -> Void
    var onCopyText: (String) -> Void
    var onClose: () -> Void

    @State private var isFavorite = false
    @State private var isPinned = false
    @State private var isComparisonVisible = false
    @State private var favoriteErrorMessage: String?
    @State private var currentItem: TranslationHistoryItem?
    @State private var previousItem: TranslationHistoryItem?
    @State private var selectedTranslationMode: TranslationMode = .accurate
    @State private var isRetranslating = false
    @State private var retranslateErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            contentArea
            footer
        }
        .padding(16)
        .frame(width: isComparisonVisible ? 780 : 540, height: isComparisonVisible ? 580 : 540, alignment: .topLeading)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.42), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 18, x: 0, y: 10)
        .background(WindowDragView())
        .task(id: resultTaskID) {
            syncResultState()
        }
        .task(id: favoriteTaskID) {
            await refreshFavoriteState()
        }
    }

    private var panelBackground: some ShapeStyle {
        .background
    }

    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            aiModeControl

            switch state {
            case .loading(let sourceText):
                sourceSection(text: sourceText, placeholder: "正在读取原文...")
                translationSection(text: nil, placeholder: "译文会在完成后显示")
            case .result:
                if isComparisonVisible, let pair = comparisonPair {
                    comparisonContent(previous: pair.previous, current: pair.current)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                            removal: .opacity
                        ))
                } else {
                    sourceSection(text: resultItem?.sourceText, placeholder: "无原文")
                    translationSection(text: resultItem?.translatedText, placeholder: "无译文")
                        .transition(.opacity)
                }
            case .error(let message, let sourceText):
                sourceSection(text: sourceText, placeholder: "暂无原文")
                errorSection(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .layoutPriority(1)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(headerTint)
                .frame(width: 28, height: 28)
                .background(headerTint.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(headerStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if case .result(let item) = state {
                Text(item.mode.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor), in: Capsule())
            }

            Button {
                isPinned.toggle()
                onPinnedChange(isPinned)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color(NSColor.controlBackgroundColor), in: Circle())
            }
            .buttonStyle(.plain)
            .help(isPinned ? "取消钉住" : "钉住窗口，点击空白处不关闭")
        }
    }

    private var headerTitle: String {
        switch state {
        case .loading:
            "正在处理"
        case .result:
            "翻译结果"
        case .error:
            "翻译失败"
        }
    }

    private var headerIcon: String {
        switch state {
        case .loading:
            "arrow.triangle.2.circlepath"
        case .result:
            "text.bubble"
        case .error:
            "exclamationmark.triangle"
        }
    }

    private var headerTint: Color {
        switch state {
        case .loading:
            .accentColor
        case .result:
            .green
        case .error:
            .red
        }
    }

    private var headerStatus: String {
        switch state {
        case .loading:
            "正在识别或翻译，请稍候"
        case .result:
            resultItem?.providerID.displayName ?? "翻译服务"
        case .error:
            "请检查权限、网络或服务商配置"
        }
    }

    private var resultTaskID: UUID? {
        if case .result(let item) = state {
            item.id
        } else {
            nil
        }
    }

    private var favoriteTaskID: UUID? {
        resultItem?.id
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            statusIndicator
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .result:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch state {
        case .loading:
            "处理中"
        case .result:
            isRetranslating
                ? "正在按 \(selectedTranslationMode.displayName) 重新翻译"
                : "已完成 · \(resultItem?.translationMode.displayName ?? "AI 模式")"
        case .error:
            "需要处理"
        }
    }

    @ViewBuilder
    private var aiModeControl: some View {
        if let item = resultItem, item.providerID.supportsTranslationModePrompts {
            HStack(spacing: 8) {
                Label("AI 模式", systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Picker("", selection: $selectedTranslationMode) {
                    ForEach(TranslationMode.allCases) { mode in
                        Text(mode.displayName)
                            .tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .disabled(isRetranslating)
                .onChange(of: selectedTranslationMode) { nextMode in
                    guard let item = resultItem, nextMode != item.translationMode else {
                        return
                    }
                    Task {
                        await retranslate(item, using: nextMode)
                    }
                }

                if isRetranslating {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Text(selectedTranslationMode.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if resultItem != nil {
            Text("当前服务商不支持 AI 模式重译")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func sourceSection(text: String?, placeholder: String) -> some View {
        textSection(
            title: "原文",
            text: text,
            placeholder: placeholder,
            minHeight: 96,
            maxHeight: 132,
            isEmphasized: false
        )
    }

    private func translationSection(text: String?, placeholder: String) -> some View {
        textSection(
            title: "译文",
            text: text,
            placeholder: placeholder,
            minHeight: 170,
            maxHeight: 248,
            isEmphasized: true
        )
    }

    private func comparisonContent(
        previous: TranslationHistoryItem,
        current: TranslationHistoryItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sourcePreview(text: current.sourceText)

            HStack(alignment: .top, spacing: 10) {
                comparisonCard(
                    title: "上一版",
                    item: previous,
                    tint: .secondary
                )

                comparisonCard(
                    title: "当前",
                    item: current,
                    tint: .accentColor
                )
            }
            .frame(maxWidth: .infinity, maxHeight: 250, alignment: .top)
        }
    }

    private func sourcePreview(text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("原文")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func comparisonCard(
        title: String,
        item: TranslationHistoryItem,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(item.translationMode.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.12), in: Capsule())

                Spacer()
            }

            ScrollView {
                Text(item.translatedText)
                    .font(.system(size: 16))
                    .lineSpacing(4.5)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 1)
        )
    }

    private func textSection(
        title: String,
        text: String?,
        placeholder: String,
        minHeight: CGFloat,
        maxHeight: CGFloat,
        isEmphasized: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayText(text, placeholder: placeholder))
                        .font(.system(size: isEmphasized ? 18 : 16, weight: .regular))
                        .lineSpacing(isEmphasized ? 5 : 4)
                        .foregroundStyle(textColor(hasText: hasText(text), isEmphasized: isEmphasized))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: maxHeight, alignment: .topLeading)
            .background(sectionBackground(isEmphasized: isEmphasized), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(NSColor.separatorColor).opacity(isEmphasized ? 0.45 : 0.25), lineWidth: 1)
            )
        }
    }

    private func textColor(hasText: Bool, isEmphasized: Bool) -> Color {
        guard hasText else {
            return .secondary
        }
        return isEmphasized ? .primary : .secondary
    }

    private func errorSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("错误信息")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                .padding(10)
                .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.red.opacity(0.22), lineWidth: 1)
                )
        }
    }

    private func sectionBackground(isEmphasized: Bool) -> Color {
        if isEmphasized {
            return Color(NSColor.textBackgroundColor).opacity(0.72)
        }
        return Color(NSColor.controlBackgroundColor).opacity(0.9)
    }

    private func displayText(_ text: String?, placeholder: String) -> String {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return placeholder
        }
        return text
    }

    private func hasText(_ text: String?) -> Bool {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let favoriteErrorMessage {
                Text(favoriteErrorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            if let retranslateErrorMessage {
                Text(retranslateErrorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Button {
                    if let item = resultItem {
                        onCopyText(item.translatedText)
                    }
                } label: {
                    Label("复制译文", systemImage: "doc.on.doc")
                }
                .disabled(resultItem == nil)

                Button {
                    if let item = resultItem {
                        onCopyText(bilingualText(for: item))
                    }
                } label: {
                    Label("复制双语", systemImage: "text.append")
                }
                .disabled(resultItem == nil)

                Button {
                    if let item = resultItem {
                        Task {
                            await toggleFavorite(item)
                        }
                    }
                } label: {
                    Label(
                        isFavorite ? "已收藏" : "收藏",
                        systemImage: isFavorite ? "star.fill" : "star"
                    )
                }
                .disabled(resultItem == nil)

                Button {
                    guard comparisonPair != nil else {
                        return
                    }
                    setComparisonVisible(!isComparisonVisible)
                } label: {
                    Label(isComparisonVisible ? "收起对比" : "对比", systemImage: "rectangle.split.2x1")
                }
                .disabled(comparisonPair == nil)

                Spacer()

                Button {
                    onClose()
                } label: {
                    Label("关闭", systemImage: "xmark")
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var resultItem: TranslationHistoryItem? {
        if let currentItem {
            return currentItem
        }
        if case .result(let item) = state {
            return item
        }
        return nil
    }

    private var comparisonPair: (previous: TranslationHistoryItem, current: TranslationHistoryItem)? {
        guard let previousItem, let resultItem else {
            return nil
        }
        return (previousItem, resultItem)
    }

    private func bilingualText(for item: TranslationHistoryItem) -> String {
        "\(item.sourceText)\n\n\(item.translatedText)"
    }

    private func syncResultState() {
        guard case .result(let item) = state else {
            currentItem = nil
            previousItem = nil
            retranslateErrorMessage = nil
            isRetranslating = false
            isComparisonVisible = false
            isPinned = false
            onComparisonLayoutChange(false)
            onPinnedChange(false)
            selectedTranslationMode = .accurate
            return
        }

        currentItem = item
        previousItem = nil
        retranslateErrorMessage = nil
        isRetranslating = false
        isComparisonVisible = false
        onComparisonLayoutChange(false)
        selectedTranslationMode = item.translationMode
    }

    private func retranslate(_ item: TranslationHistoryItem, using mode: TranslationMode) async {
        guard !isRetranslating else {
            return
        }

        isRetranslating = true
        retranslateErrorMessage = nil
        defer {
            isRetranslating = false
        }

        do {
            let updatedItem = try await onRetranslate(item, mode)
            previousItem = item
            currentItem = updatedItem
            selectedTranslationMode = updatedItem.translationMode
            favoriteErrorMessage = nil
            setComparisonVisible(true)
        } catch {
            retranslateErrorMessage = error.localizedDescription
            selectedTranslationMode = item.translationMode
        }
    }

    private func refreshFavoriteState() async {
        guard let item = resultItem else {
            isFavorite = false
            favoriteErrorMessage = nil
            return
        }

        do {
            isFavorite = try await favoriteStore.isFavorite(historyItemID: item.id)
            favoriteErrorMessage = nil
        } catch {
            favoriteErrorMessage = error.localizedDescription
        }
    }

    private func toggleFavorite(_ item: TranslationHistoryItem) async {
        do {
            if isFavorite {
                try await favoriteStore.removeFavorite(historyItemID: item.id)
                isFavorite = false
            } else {
                try await favoriteStore.addFavorite(item)
                isFavorite = true
            }
            favoriteErrorMessage = nil
        } catch {
            favoriteErrorMessage = error.localizedDescription
        }
    }

    private func setComparisonVisible(_ isVisible: Bool) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            isComparisonVisible = isVisible
        }
        onComparisonLayoutChange(isVisible)
    }
}

private extension FloatingTranslatePanel {
    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.postsFrameChangedNotifications = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isMovableByWindowBackground = true
    }
}
