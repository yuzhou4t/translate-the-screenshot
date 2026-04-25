import AppKit
import SwiftUI

@MainActor
final class FloatingTranslatePanel {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<FloatingTranslateView>?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private let favoriteStore: FavoriteStore
    private let panelSize = NSSize(width: 440, height: 300)

    init(favoriteStore: FavoriteStore) {
        self.favoriteStore = favoriteStore
    }

    func showLoading(sourceText: String?, near point: NSPoint) {
        show(state: .loading(sourceText: sourceText), near: point)
    }

    func showResult(item: TranslationHistoryItem, near point: NSPoint) {
        show(state: .result(item), near: point)
    }

    func showError(_ message: String, near point: NSPoint) {
        show(state: .error(message), near: point)
    }

    private func show(state: FloatingTranslateState, near point: NSPoint) {
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
            newPanel.appearance = NSAppearance(named: .aqua)
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

        panel?.setFrame(NSRect(origin: origin(for: point), size: panelSize), display: true)
        panel?.orderFrontRegardless()
        installDismissMonitorsIfNeeded()
    }

    func hide() {
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
    case error(String)
}

struct FloatingTranslateView: View {
    var state: FloatingTranslateState
    var favoriteStore: FavoriteStore
    var onCopyText: (String) -> Void
    var onClose: () -> Void

    @State private var isFavorite = false
    @State private var favoriteErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch state {
            case .loading(let sourceText):
                loadingView(sourceText: sourceText)
            case .result(let item):
                resultView(item)
            case .error(let message):
                errorView(message)
            }
        }
        .padding(14)
        .frame(width: 440, height: 300, alignment: .topLeading)
        .background(Color(red: 0.96, green: 0.96, blue: 0.95))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 22, x: 0, y: 10)
        .background(WindowDragView())
        .preferredColorScheme(.light)
        .task(id: favoriteTaskID) {
            await refreshFavoriteState()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.62))
                .frame(width: 22, height: 22)
                .background(Color.black.opacity(0.07), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("TTS")
                    .font(.headline)
                    .foregroundStyle(Color.black.opacity(0.88))
                Text(headerStatus)
                    .font(.caption2)
                    .foregroundStyle(Color.black.opacity(0.55))
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.black.opacity(0.64))
            .background(Color.black.opacity(0.07), in: Circle())
            .help("关闭")
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

    private var headerStatus: String {
        switch state {
        case .loading:
            "正在翻译"
        case .result(let item):
            item.providerID.displayName
        case .error:
            "需要处理"
        }
    }

    private var favoriteTaskID: UUID? {
        if case .result(let item) = state {
            item.id
        } else {
            nil
        }
    }

    private func loadingView(sourceText: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在翻译...")
                    .font(.subheadline)
                    .foregroundStyle(Color.black.opacity(0.62))
            }

            if let sourceText, !sourceText.isEmpty {
                Text(sourceText)
                    .font(.callout)
                    .foregroundStyle(Color.black.opacity(0.62))
                    .lineLimit(6)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text("正在读取选中文字...")
                    .font(.callout)
                    .foregroundStyle(Color.black.opacity(0.62))
            }
        }
        .padding(.top, 8)
    }

    private func resultView(_ item: TranslationHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.sourceText)
                .font(.caption)
                .foregroundStyle(Color.black.opacity(0.58))
                .lineLimit(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            ScrollView {
                Text(item.translatedText)
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .lineSpacing(3)
                    .foregroundStyle(Color.black.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: .infinity)
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )

            if let favoriteErrorMessage {
                Text(favoriteErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Button {
                    onCopyText(item.translatedText)
                } label: {
                    Label("复制译文", systemImage: "doc.on.doc")
                }

                Button {
                    onCopyText(item.sourceText)
                } label: {
                    Label("复制原文", systemImage: "doc")
                }

                Button {
                    Task {
                        await toggleFavorite(item)
                    }
                } label: {
                    Label(
                        isFavorite ? "已收藏" : "收藏",
                        systemImage: isFavorite ? "star.fill" : "star"
                    )
                }

                Spacer()
            }
            .controlSize(.small)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("翻译失败")
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(Color.black.opacity(0.68))
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
