import AppKit
import SwiftUI

@MainActor
final class ToastPanel {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<ToastView>?
    private var dismissTask: Task<Void, Never>?
    private let panelSize = NSSize(width: 220, height: 56)

    func show(_ message: String, near point: NSPoint? = nil) {
        dismissTask?.cancel()

        let view = ToastView(message: message)
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
            panel = newPanel
        }

        if let hostingController {
            hostingController.rootView = view
        } else {
            let controller = NSHostingController(rootView: view)
            hostingController = controller
            panel?.contentViewController = controller
        }

        panel?.setFrame(NSRect(origin: origin(near: point), size: panelSize), display: true)
        panel?.orderFrontRegardless()

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            await MainActor.run {
                self?.panel?.orderOut(nil)
            }
        }
    }

    private func origin(near point: NSPoint?) -> NSPoint {
        let screen = point.flatMap { point in
            NSScreen.screens.first { $0.frame.contains(point) }
        } ?? NSScreen.main

        guard let visibleFrame = screen?.visibleFrame else {
            return NSPoint(x: 80, y: 80)
        }

        if let point {
            let preferred = NSPoint(x: point.x + 14, y: point.y - panelSize.height - 14)
            let x = min(max(preferred.x, visibleFrame.minX + 8), visibleFrame.maxX - panelSize.width - 8)
            let y = min(max(preferred.y, visibleFrame.minY + 8), visibleFrame.maxY - panelSize.height - 8)
            return NSPoint(x: x, y: y)
        }

        return NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.maxY - panelSize.height - 64
        )
    }
}

private struct ToastView: View {
    var message: String

    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 220, height: 56)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}
