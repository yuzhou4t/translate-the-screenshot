import AppKit
import SwiftUI

@MainActor
final class FloatingTranslatePanel {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<FloatingTranslateView>?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private let favoriteStore: FavoriteStore
    private let panelSize = NSSize(width: 480, height: 360)
    private var currentPresentationID: UUID?
    private var dismissedPresentationID: UUID?
    private var currentSourceText: String?

    init(favoriteStore: FavoriteStore) {
        self.favoriteStore = favoriteStore
    }

    @discardableResult
    func showLoading(sourceText: String?, near point: NSPoint) -> UUID {
        let presentationID = UUID()
        currentPresentationID = presentationID
        dismissedPresentationID = nil
        currentSourceText = sourceText
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
            onCopyText: copyToPasteboard(_:),
            onClose: hide
        )

        if panel == nil {
            let newPanel = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
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
            panel?.setFrame(NSRect(origin: origin(for: point), size: panelSize), display: true)
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

        if !panel.frame.contains(NSEvent.mouseLocation) {
            hide()
        }
    }

    private func origin(for point: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { screen in
            screen.frame.contains(point)
        } ?? NSScreen.main

        guard let visibleFrame = screen?.visibleFrame else {
            return NSPoint(x: point.x + 12, y: point.y - panelSize.height - 12)
        }

        let preferred = NSPoint(x: point.x + 14, y: point.y - panelSize.height - 14)
        let x = min(max(preferred.x, visibleFrame.minX + 8), visibleFrame.maxX - panelSize.width - 8)
        let y = min(max(preferred.y, visibleFrame.minY + 8), visibleFrame.maxY - panelSize.height - 8)
        return NSPoint(x: x, y: y)
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
    var onCopyText: (String) -> Void
    var onClose: () -> Void

    @State private var isFavorite = false
    @State private var favoriteErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            contentArea
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(width: 480, height: 360, alignment: .topLeading)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.42), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 18, x: 0, y: 10)
        .background(WindowDragView())
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

            switch state {
            case .loading(let sourceText):
                sourceSection(text: sourceText, placeholder: "正在读取原文...")
                translationSection(text: nil, placeholder: "译文会在完成后显示")
            case .result(let item):
                sourceSection(text: item.sourceText, placeholder: "无原文")
                translationSection(text: item.translatedText, placeholder: "无译文")
            case .error(let message, let sourceText):
                sourceSection(text: sourceText, placeholder: "暂无原文")
                errorSection(message)
            }
        }
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
                    .font(.system(size: 15, weight: .semibold))
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
        case .result(let item):
            item.providerID.displayName
        case .error:
            "请检查权限、网络或服务商配置"
        }
    }

    private var favoriteTaskID: UUID? {
        if case .result(let item) = state {
            item.id
        } else {
            nil
        }
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
        case .result(let item):
            "已完成 · \(item.providerID.displayName)"
        case .error:
            "需要处理"
        }
    }

    private func sourceSection(text: String?, placeholder: String) -> some View {
        textSection(
            title: "原文",
            text: text,
            placeholder: placeholder,
            minHeight: 62,
            lineLimit: 3,
            isEmphasized: false
        )
    }

    private func translationSection(text: String?, placeholder: String) -> some View {
        textSection(
            title: "译文",
            text: text,
            placeholder: placeholder,
            minHeight: 112,
            lineLimit: nil,
            isEmphasized: true
        )
    }

    private func textSection(
        title: String,
        text: String?,
        placeholder: String,
        minHeight: CGFloat,
        lineLimit: Int?,
        isEmphasized: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Group {
                if isEmphasized {
                    ScrollView {
                        Text(displayText(text, placeholder: placeholder))
                            .font(.system(size: 15, weight: .regular))
                            .lineSpacing(3)
                            .foregroundStyle(hasText(text) ? Color.primary : Color.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(displayText(text, placeholder: placeholder))
                        .font(.caption)
                        .foregroundStyle(hasText(text) ? Color.secondary : Color.secondary.opacity(0.75))
                        .lineLimit(lineLimit)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(sectionBackground(isEmphasized: isEmphasized), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(NSColor.separatorColor).opacity(isEmphasized ? 0.45 : 0.25), lineWidth: 1)
            )
        }
    }

    private func errorSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("错误信息")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.callout)
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

                Spacer()

                Button {
                    onClose()
                } label: {
                    Label("关闭", systemImage: "xmark")
                }
            }
            .controlSize(.small)
        }
    }

    private var resultItem: TranslationHistoryItem? {
        if case .result(let item) = state {
            return item
        }
        return nil
    }

    private func bilingualText(for item: TranslationHistoryItem) -> String {
        "\(item.sourceText)\n\n\(item.translatedText)"
    }

    private func refreshFavoriteState() async {
        guard case .result(let item) = state else {
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
