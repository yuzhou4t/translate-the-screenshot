import AppKit
import ScreenCaptureKit
import SwiftUI

struct ScreenRecordingWindowCandidate: Equatable, Sendable {
    var target: ScreenRecordingTarget
    var frame: CGRect
}

@MainActor
final class ScreenRecordingSelectionModel: ObservableObject {
    @Published var mode: ScreenRecordingMode = .region
    @Published var options: ScreenRecordingOptions = .default
    @Published var canRecordRegion = false
}

@MainActor
final class ScreenRecordingSelectionController {
    var onTargetSelected: ((ScreenRecordingTarget, ScreenRecordingOptions) -> Void)?
    var onCancelled: (() -> Void)?
    var onMicrophoneToggle: ((Bool) -> Void)?

    private let model = ScreenRecordingSelectionModel()
    private var overlayWindows: [ScreenRecordingSelectionWindow] = []
    private var toolbarPanel: NSPanel?
    private var currentRegionTarget: ScreenRecordingTarget?

    func present(shareableContent: SCShareableContent) throws {
        dismiss()
        model.mode = .region
        model.options = .default
        model.canRecordRegion = false
        currentRegionTarget = nil

        let primaryScreenMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let ownBundleID = Bundle.main.bundleIdentifier
        let candidates = shareableContent.windows.compactMap { window -> ScreenRecordingWindowCandidate? in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.frame.width >= 40,
                  window.frame.height >= 40,
                  window.owningApplication?.bundleIdentifier != ownBundleID else {
                return nil
            }
            let frame = ScreenRecordingGeometry.appKitRect(
                fromQuartzRect: window.frame,
                primaryScreenMaxY: primaryScreenMaxY
            )
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let appName = window.owningApplication?.applicationName ?? "窗口"
            let displayTitle = title?.isEmpty == false ? title! : appName
            return ScreenRecordingWindowCandidate(
                target: .window(id: window.windowID, frame: frame, title: displayTitle),
                frame: frame
            )
        }

        for screen in NSScreen.screens {
            guard let displayID = ScreenRecordingGeometry.displayID(for: screen),
                  shareableContent.displays.contains(where: { $0.displayID == displayID }) else {
                continue
            }
            let target = ScreenRecordingTarget.display(id: displayID, frame: screen.frame)
            let window = ScreenRecordingSelectionWindow(
                screen: screen,
                displayTarget: target,
                windowCandidates: candidates
            )
            window.onTargetSelected = { [weak self] target in
                self?.finish(with: target)
            }
            window.onRegionChanged = { [weak self, weak window] rect in
                guard let self, let window else { return }
                self.updateRegion(rect, from: window)
            }
            window.onCancelled = { [weak self] in
                self?.cancel()
            }
            window.setMode(model.mode)
            overlayWindows.append(window)
        }

        guard !overlayWindows.isEmpty else {
            throw ScreenRecordingError.noShareableContent
        }

        let toolbarView = ScreenRecordingToolbarView(
            model: model,
            onModeChanged: { [weak self] mode in
                self?.setMode(mode)
            },
            onMicrophoneToggle: { [weak self] enabled in
                self?.onMicrophoneToggle?(enabled)
            },
            onRecordRegion: { [weak self] in
                guard let self, let target = self.currentRegionTarget else { return }
                self.finish(with: target)
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )
        let controller = NSHostingController(rootView: toolbarView)
        let size = NSSize(width: 830, height: 104)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.setFrameOrigin(toolbarOrigin(for: size))
        toolbarPanel = panel

        overlayWindows.forEach { $0.orderFrontRegardless() }
        overlayWindows.first?.makeKey()
        panel.orderFrontRegardless()
    }

    func updateMicrophoneOption(_ enabled: Bool) {
        model.options.capturesMicrophone = enabled
    }

    func dismiss() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
        currentRegionTarget = nil
        model.canRecordRegion = false
    }

    private func setMode(_ mode: ScreenRecordingMode) {
        model.mode = mode
        currentRegionTarget = nil
        model.canRecordRegion = false
        overlayWindows.forEach {
            $0.setMode(mode)
            $0.setRegionSelection(nil)
        }
    }

    private func updateRegion(_ globalRect: CGRect?, from sourceWindow: ScreenRecordingSelectionWindow) {
        overlayWindows.filter { $0 !== sourceWindow }.forEach { $0.setRegionSelection(nil) }
        guard let globalRect,
              let clipped = ScreenRecordingGeometry.clampedRegion(
                  globalRect,
                  to: sourceWindow.screenFrame
              ),
              case let .display(displayID, _) = sourceWindow.displayTarget else {
            currentRegionTarget = nil
            model.canRecordRegion = false
            return
        }
        currentRegionTarget = .region(
            displayID: displayID,
            displayFrame: sourceWindow.screenFrame,
            rect: clipped
        )
        model.canRecordRegion = true
    }

    private func finish(with target: ScreenRecordingTarget) {
        let options = model.options
        dismiss()
        onTargetSelected?(target, options)
    }

    private func cancel() {
        dismiss()
        onCancelled?()
    }

    private func toolbarOrigin(for size: NSSize) -> NSPoint {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        return NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 24
        )
    }
}

@MainActor
final class ScreenRecordingSelectionWindow: NSPanel {
    var onTargetSelected: ((ScreenRecordingTarget) -> Void)? {
        didSet { selectionView.onTargetSelected = onTargetSelected }
    }
    var onRegionChanged: ((CGRect?) -> Void)? {
        didSet { selectionView.onRegionChanged = onRegionChanged }
    }
    var onCancelled: (() -> Void)? {
        didSet { selectionView.onCancelled = onCancelled }
    }

    let displayTarget: ScreenRecordingTarget
    let screenFrame: CGRect
    private let selectionView: ScreenRecordingSelectionView

    init(
        screen: NSScreen,
        displayTarget: ScreenRecordingTarget,
        windowCandidates: [ScreenRecordingWindowCandidate]
    ) {
        self.displayTarget = displayTarget
        screenFrame = screen.frame
        selectionView = ScreenRecordingSelectionView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            screenFrame: screen.frame,
            displayTarget: displayTarget,
            windowCandidates: windowCandidates
        )
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentView = selectionView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancelled?()
    }

    func setMode(_ mode: ScreenRecordingMode) {
        selectionView.setMode(mode)
    }

    func setRegionSelection(_ rect: CGRect?) {
        selectionView.setRegionSelection(rect)
    }
}

@MainActor
private final class ScreenRecordingSelectionView: NSView {
    var onTargetSelected: ((ScreenRecordingTarget) -> Void)?
    var onRegionChanged: ((CGRect?) -> Void)?
    var onCancelled: (() -> Void)?

    private enum DragOperation {
        case create(anchor: CGPoint)
        case move(original: CGRect, anchor: CGPoint)
        case resize(original: CGRect, anchor: CGPoint, edges: ScreenshotSelectionResizeEdges)
    }

    private let screenFrame: CGRect
    private let displayTarget: ScreenRecordingTarget
    private let windowCandidates: [ScreenRecordingWindowCandidate]
    private var mode: ScreenRecordingMode = .region
    private var regionRect: CGRect?
    private var highlightedWindow: ScreenRecordingWindowCandidate?
    private var isPointerInside = false
    private var dragOperation: DragOperation?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    init(
        frame frameRect: NSRect,
        screenFrame: CGRect,
        displayTarget: ScreenRecordingTarget,
        windowCandidates: [ScreenRecordingWindowCandidate]
    ) {
        self.screenFrame = screenFrame
        self.displayTarget = displayTarget
        self.windowCandidates = windowCandidates
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(mode == .region ? 0.24 : 0.13).setFill()
        if mode == .region, let regionRect {
            let mask = NSBezierPath(rect: bounds)
            mask.appendRect(regionRect)
            mask.windingRule = .evenOdd
            mask.fill()
            drawSelection(rect: regionRect, label: "\(Int(regionRect.width)) × \(Int(regionRect.height))")
        } else {
            bounds.fill()
        }

        switch mode {
        case .display where isPointerInside:
            drawSelection(rect: bounds.insetBy(dx: 3, dy: 3), label: "点击录制这块屏幕")
        case .window:
            if let highlightedWindow {
                let localRect = globalToLocal(highlightedWindow.frame).intersection(bounds)
                drawSelection(rect: localRect, label: highlightedWindow.target.description)
            }
        case .region where regionRect == nil:
            drawCenteredHint("拖动框选录制区域")
        case .display, .region:
            break
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updatePointer(event)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        highlightedWindow = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        switch mode {
        case .display:
            onTargetSelected?(displayTarget)
        case .window:
            updatePointer(event)
            if let highlightedWindow {
                onTargetSelected?(highlightedWindow.target)
            }
        case .region:
            if let regionRect {
                let edges = resizeEdges(at: point, in: regionRect)
                if !edges.isEmpty {
                    dragOperation = .resize(original: regionRect, anchor: point, edges: edges)
                } else if regionRect.contains(point) {
                    dragOperation = .move(original: regionRect, anchor: point)
                } else {
                    dragOperation = .create(anchor: point)
                    self.regionRect = CGRect(origin: point, size: .zero)
                }
            } else {
                dragOperation = .create(anchor: point)
                regionRect = CGRect(origin: point, size: .zero)
            }
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region, let dragOperation else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        switch dragOperation {
        case let .create(anchor):
            regionRect = CGRect(
                x: min(anchor.x, point.x),
                y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x),
                height: abs(point.y - anchor.y)
            )
        case let .move(original, anchor):
            let delta = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
            regionRect = ScreenshotCaptureController.movedSelectionRect(
                original,
                by: delta,
                within: bounds
            )
        case let .resize(original, anchor, edges):
            let delta = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
            regionRect = ScreenshotCaptureController.resizedSelectionRect(
                original,
                edges: edges,
                by: delta,
                within: bounds
            )
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .region else { return }
        dragOperation = nil
        guard let regionRect,
              let valid = ScreenRecordingGeometry.clampedRegion(regionRect, to: bounds) else {
            self.regionRect = nil
            onRegionChanged?(nil)
            needsDisplay = true
            return
        }
        self.regionRect = valid
        onRegionChanged?(localToGlobal(valid))
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancelled?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancelled?()
        } else {
            super.keyDown(with: event)
        }
    }

    func setMode(_ mode: ScreenRecordingMode) {
        self.mode = mode
        highlightedWindow = nil
        dragOperation = nil
        needsDisplay = true
    }

    func setRegionSelection(_ globalRect: CGRect?) {
        regionRect = globalRect.map(globalToLocal)
        needsDisplay = true
    }

    private func updatePointer(_ event: NSEvent) {
        guard mode == .window else {
            needsDisplay = true
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        let global = CGPoint(x: local.x + screenFrame.minX, y: local.y + screenFrame.minY)
        highlightedWindow = windowCandidates.first { $0.frame.contains(global) }
        needsDisplay = true
    }

    private func resizeEdges(at point: CGPoint, in rect: CGRect) -> ScreenshotSelectionResizeEdges {
        let tolerance: CGFloat = 8
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return [] }
        var edges: ScreenshotSelectionResizeEdges = []
        if abs(point.x - rect.minX) <= tolerance { edges.insert(.minX) }
        if abs(point.x - rect.maxX) <= tolerance { edges.insert(.maxX) }
        if abs(point.y - rect.minY) <= tolerance { edges.insert(.minY) }
        if abs(point.y - rect.maxY) <= tolerance { edges.insert(.maxY) }
        return edges
    }

    private func drawSelection(rect: CGRect, label: String) {
        NSColor.ttsSelectionAccent.withAlphaComponent(0.12).setFill()
        rect.fill()
        let border = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        border.lineWidth = 3
        NSColor.white.setStroke()
        border.stroke()
        let accent = NSBezierPath(rect: rect.insetBy(dx: 2.5, dy: 2.5))
        accent.lineWidth = 2
        NSColor.ttsSelectionAccent.setStroke()
        accent.stroke()
        drawLabel(label, near: rect)
    }

    private func drawLabel(_ text: String, near rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let value = NSAttributedString(string: text, attributes: attributes)
        let textSize = value.size()
        let labelRect = CGRect(
            x: min(max(rect.minX, bounds.minX + 8), bounds.maxX - textSize.width - 26),
            y: max(bounds.minY + 8, rect.maxY - textSize.height - 22),
            width: textSize.width + 18,
            height: textSize.height + 10
        )
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 7, yRadius: 7).fill()
        value.draw(at: CGPoint(x: labelRect.minX + 9, y: labelRect.minY + 5))
    }

    private func drawCenteredHint(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let value = NSAttributedString(string: text, attributes: attributes)
        let size = value.size()
        value.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    private func globalToLocal(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    private func localToGlobal(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}

private struct ScreenRecordingToolbarView: View {
    @ObservedObject var model: ScreenRecordingSelectionModel
    var onModeChanged: (ScreenRecordingMode) -> Void
    var onMicrophoneToggle: (Bool) -> Void
    var onRecordRegion: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                ForEach(ScreenRecordingMode.allCases) { mode in
                    Button {
                        onModeChanged(mode)
                    } label: {
                        Label(mode.displayName, systemImage: mode.systemImage)
                            .frame(minWidth: 104, minHeight: 31)
                    }
                    .buttonStyle(.plain)
                    .background(
                        model.mode == mode ? TTSVisualStyle.accent.opacity(0.2) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .foregroundStyle(model.mode == mode ? TTSVisualStyle.accentStrong : Color.primary)
                }

                Divider().frame(height: 30)

                optionToggle(
                    "系统声音",
                    systemImage: model.options.capturesSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    isOn: Binding(
                        get: { model.options.capturesSystemAudio },
                        set: { model.options.capturesSystemAudio = $0 }
                    )
                )
                optionToggle(
                    "麦克风",
                    systemImage: model.options.capturesMicrophone ? "mic.fill" : "mic.slash.fill",
                    isOn: Binding(
                        get: { model.options.capturesMicrophone },
                        set: {
                            model.options.capturesMicrophone = $0
                            onMicrophoneToggle($0)
                        }
                    )
                )
                optionToggle(
                    "光标",
                    systemImage: "cursorarrow",
                    isOn: Binding(
                        get: { model.options.showsCursor },
                        set: { model.options.showsCursor = $0 }
                    )
                )

                Divider().frame(height: 30)

                if model.mode == .region {
                    Button("录制") { onRecordRegion() }
                        .buttonStyle(TTSPrimaryButtonStyle())
                        .disabled(!model.canRecordRegion)
                } else {
                    Text("点击目标开始")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 78)
                }

                Button("取消") { onCancel() }
                    .buttonStyle(TTSSecondaryButtonStyle())
            }

            Text(model.options.isSilent ? "静音录屏 · Esc 取消" : "3 秒倒计时 · Esc 取消")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 830, height: 104)
        .background(TTSWindowBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(TTSVisualStyle.border, lineWidth: 1)
        }
        .tint(TTSVisualStyle.accent)
    }

    private func optionToggle(
        _ title: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(height: 31)
        .background(isOn.wrappedValue ? TTSVisualStyle.accent.opacity(0.16) : TTSVisualStyle.controlSurface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
