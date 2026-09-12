import AppKit
import SwiftUI

@MainActor
final class ScreenRecordingCountdownPanel {
    var onCancel: (() -> Void)?

    private var panel: ScreenRecordingCountdownNSPanel?
    private var hostingController: NSHostingController<ScreenRecordingCountdownView>?

    func show(_ remaining: Int, centeredIn targetRect: CGRect) {
        let view = ScreenRecordingCountdownView(remaining: remaining)
        let size = NSSize(width: 116, height: 116)
        if panel == nil {
            let next = ScreenRecordingCountdownNSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            next.isOpaque = false
            next.backgroundColor = .clear
            next.hasShadow = true
            next.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            next.isReleasedWhenClosed = false
            panel = next
        }
        panel?.onCancel = onCancel

        if let hostingController {
            hostingController.rootView = view
        } else {
            let controller = NSHostingController(rootView: view)
            hostingController = controller
            panel?.contentViewController = controller
        }

        let frame = CGRect(
            x: targetRect.midX - size.width / 2,
            y: targetRect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
        panel?.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

@MainActor
private final class ScreenRecordingCountdownNSPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private struct ScreenRecordingCountdownView: View {
    var remaining: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.8))
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 3)
            Text("\(remaining)")
                .font(.system(size: 54, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
        }
        .padding(8)
        .frame(width: 116, height: 116)
    }
}

@MainActor
final class ScreenRecordingCompletionPanel {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<ScreenRecordingCompletionView>?
    private var dismissTask: Task<Void, Never>?

    func show(fileURL: URL, message: String = "录屏已保存") {
        dismissTask?.cancel()
        let view = ScreenRecordingCompletionView(
            message: message,
            filename: fileURL.lastPathComponent,
            onOpen: {
                NSWorkspace.shared.open(fileURL)
            },
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )
        let size = NSSize(width: 340, height: 126)
        if panel == nil {
            let next = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            next.isOpaque = false
            next.backgroundColor = .clear
            next.hasShadow = true
            next.level = .floating
            next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            next.isReleasedWhenClosed = false
            panel = next
        }

        if let hostingController {
            hostingController.rootView = view
        } else {
            let controller = NSHostingController(rootView: view)
            hostingController = controller
            panel?.contentViewController = controller
        }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        panel?.setFrame(
            CGRect(
                x: visibleFrame.maxX - size.width - 24,
                y: visibleFrame.maxY - size.height - 24,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        panel?.orderFrontRegardless()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
    }
}

private struct ScreenRecordingCompletionView: View {
    var message: String
    var filename: String
    var onOpen: () -> Void
    var onReveal: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message)
                        .font(.headline)
                    Text(filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Button("打开视频", action: onOpen)
                    .buttonStyle(TTSPrimaryButtonStyle())
                Button("在访达中显示", action: onReveal)
                    .buttonStyle(TTSSecondaryButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 340, height: 126)
        .background(TTSWindowBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(TTSVisualStyle.border, lineWidth: 1)
        }
        .tint(TTSVisualStyle.accent)
    }
}
