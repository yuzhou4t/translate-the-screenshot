import AppKit

@MainActor
final class ScreenshotOverlayWindow: NSPanel {
    var onFinished: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    init(screen: NSScreen) {
        let contentView = ScreenshotOverlayView(frame: screen.frame)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        contentView.onFinished = { [weak self] selectionRect in
            self?.onFinished?(selectionRect)
        }
        contentView.onCancelled = { [weak self] in
            self?.onCancelled?()
        }

        self.contentView = contentView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool {
        true
    }

    override func cancelOperation(_ sender: Any?) {
        onCancelled?()
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
    }

    func updateCrosshair(globalPoint: NSPoint) {
        guard frame.contains(globalPoint),
              let overlayView = contentView as? ScreenshotOverlayView else {
            return
        }

        let localPoint = NSPoint(
            x: globalPoint.x - frame.minX,
            y: globalPoint.y - frame.minY
        )
        overlayView.updateCrosshair(at: localPoint)
    }
}

@MainActor
private final class ScreenshotOverlayView: NSView {
    var onFinished: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var lastDragPoint: CGPoint?
    private var crosshairPoint: CGPoint?
    private var isSpacePressed = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
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
        resetCursorRects()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCrosshair(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCrosshair(at: convert(event.locationInWindow, from: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let selection = selectionRect else {
            drawCrosshairIfNeeded()
            return
        }

        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        selection.fill()

        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: selection)
        outline.lineWidth = 2
        outline.stroke()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let innerOutline = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
        innerOutline.lineWidth = 1
        innerOutline.stroke()

        drawCrosshairIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateCrosshair(at: point)
        startPoint = point
        currentPoint = point
        lastDragPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        crosshairPoint = point

        if isSpacePressed,
           let startPoint,
           let currentPoint,
           let lastDragPoint {
            let delta = CGPoint(
                x: point.x - lastDragPoint.x,
                y: point.y - lastDragPoint.y
            )
            let moved = movedSelection(
                startPoint: startPoint,
                currentPoint: currentPoint,
                delta: delta
            )
            self.startPoint = moved.start
            self.currentPoint = moved.current
        } else {
            currentPoint = point
        }

        lastDragPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if !isSpacePressed {
            currentPoint = convert(event.locationInWindow, from: nil)
        }
        guard let selectionRect, selectionRect.width >= 2, selectionRect.height >= 2 else {
            onCancelled?()
            return
        }

        guard let windowFrame = window?.frame else {
            onCancelled?()
            return
        }

        let globalRect = CGRect(
            x: windowFrame.minX + selectionRect.minX,
            y: windowFrame.minY + selectionRect.minY,
            width: selectionRect.width,
            height: selectionRect.height
        )
        onFinished?(globalRect)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancelled?()
    }

    override func otherMouseDown(with event: NSEvent) {
        onCancelled?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpacePressed = true
        } else if event.keyCode == 53 {
            onCancelled?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpacePressed = false
        } else {
            super.keyUp(with: event)
        }
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else {
            return nil
        }

        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
    }

    func updateCrosshair(at point: CGPoint) {
        guard bounds.contains(point) else {
            return
        }

        crosshairPoint = point
        needsDisplay = true
    }

    private func drawCrosshairIfNeeded() {
        guard let crosshairPoint else {
            return
        }

        let gap: CGFloat = 5
        let length: CGFloat = 18
        let whitePath = NSBezierPath()
        whitePath.move(to: CGPoint(x: crosshairPoint.x - length, y: crosshairPoint.y))
        whitePath.line(to: CGPoint(x: crosshairPoint.x - gap, y: crosshairPoint.y))
        whitePath.move(to: CGPoint(x: crosshairPoint.x + gap, y: crosshairPoint.y))
        whitePath.line(to: CGPoint(x: crosshairPoint.x + length, y: crosshairPoint.y))
        whitePath.move(to: CGPoint(x: crosshairPoint.x, y: crosshairPoint.y - length))
        whitePath.line(to: CGPoint(x: crosshairPoint.x, y: crosshairPoint.y - gap))
        whitePath.move(to: CGPoint(x: crosshairPoint.x, y: crosshairPoint.y + gap))
        whitePath.line(to: CGPoint(x: crosshairPoint.x, y: crosshairPoint.y + length))
        whitePath.lineWidth = 3
        NSColor.white.withAlphaComponent(0.95).setStroke()
        whitePath.stroke()

        let accentPath = whitePath.copy() as! NSBezierPath
        accentPath.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        accentPath.stroke()
    }

    private func movedSelection(
        startPoint: CGPoint,
        currentPoint: CGPoint,
        delta: CGPoint
    ) -> (start: CGPoint, current: CGPoint) {
        let rect = CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )

        var adjustedDelta = delta
        if rect.minX + adjustedDelta.x < bounds.minX {
            adjustedDelta.x = bounds.minX - rect.minX
        }
        if rect.maxX + adjustedDelta.x > bounds.maxX {
            adjustedDelta.x = bounds.maxX - rect.maxX
        }
        if rect.minY + adjustedDelta.y < bounds.minY {
            adjustedDelta.y = bounds.minY - rect.minY
        }
        if rect.maxY + adjustedDelta.y > bounds.maxY {
            adjustedDelta.y = bounds.maxY - rect.maxY
        }

        return (
            start: CGPoint(x: startPoint.x + adjustedDelta.x, y: startPoint.y + adjustedDelta.y),
            current: CGPoint(x: currentPoint.x + adjustedDelta.x, y: currentPoint.y + adjustedDelta.y)
        )
    }

}
