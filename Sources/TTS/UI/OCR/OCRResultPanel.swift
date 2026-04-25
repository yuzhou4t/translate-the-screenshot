import AppKit
import SwiftUI

@MainActor
final class OCRResultPanel {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<OCRResultView>?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private let panelSize = NSSize(width: 480, height: 360)

    func showLoading(near point: NSPoint) {
        show(state: .loading, near: point)
    }

    func showResult(_ result: OCRResult, imageURL: URL, near point: NSPoint) {
        show(state: .result(result, imageURL: imageURL), near: point)
    }

    func showError(_ message: String, near point: NSPoint) {
        show(state: .error(message), near: point)
    }

    func hide() {
        panel?.orderOut(nil)
        removeDismissMonitors()
    }

    private func show(state: OCRResultPanelState, near point: NSPoint) {
        let view = OCRResultView(
            state: state,
            onCopy: copyToPasteboard(_:),
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
            newPanel.isReleasedWhenClosed = false
            newPanel.isMovableByWindowBackground = true
            panel = newPanel
        }

        if let hostingController {
            hostingController.rootView = view
        } else {
            let controller = NSHostingController(rootView: view)
            hostingController = controller
            panel?.contentViewController = controller
        }

        panel?.setFrame(NSRect(origin: origin(for: point), size: panelSize), display: true)
        panel?.orderFrontRegardless()
        installDismissMonitorsIfNeeded()
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
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return NSPoint(x: point.x + 12, y: point.y - panelSize.height - 12)
        }

        let preferred = NSPoint(x: point.x + 14, y: point.y - panelSize.height - 14)
        let x = min(max(preferred.x, visibleFrame.minX + 8), visibleFrame.maxX - panelSize.width - 8)
        let y = min(max(preferred.y, visibleFrame.minY + 8), visibleFrame.maxY - panelSize.height - 8)
        return NSPoint(x: x, y: y)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private enum OCRResultPanelState: Equatable {
    case loading
    case result(OCRResult, imageURL: URL)
    case error(String)
}

private struct OCRResultView: View {
    var state: OCRResultPanelState
    var onCopy: (String) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            switch state {
            case .loading:
                loadingView
            case .result(let result, let imageURL):
                resultView(result, imageURL: imageURL)
            case .error(let message):
                errorView(message)
            }
        }
        .padding(16)
        .frame(width: 480, height: 360, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            Text("OCR 识别")
                .font(.headline)
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    private var loadingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在识别截图文字...")
                .foregroundStyle(.secondary)
        }
    }

    private func resultView(_ result: OCRResult, imageURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("置信度 \(Int(result.confidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(result.textBlocks.count) 个文本块")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView {
                Text(result.plainText.isEmpty ? "未识别到文字" : result.plainText)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button {
                    onCopy(result.plainText)
                } label: {
                    Label("复制文本", systemImage: "doc.on.doc")
                }
                .disabled(result.plainText.isEmpty)

                Text(imageURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()
            }
            .controlSize(.small)
        }
    }

    private func errorView(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }
}
