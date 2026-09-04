import AppKit

@MainActor
final class ScreenshotOverlayWindow: NSPanel {
    var onFinished: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    init(screen: NSScreen, frozenImage: CGImage) {
        let contentView = ScreenshotOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            frozenImage: frozenImage
        )
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
final class ScreenshotOverlayView: NSView {
    var onFinished: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    private let frozenImage: NSImage
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var lastDragPoint: CGPoint?
    private var crosshairPoint: CGPoint?
    private var isSpacePressed = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    init(frame frameRect: NSRect, frozenImage: CGImage) {
        self.frozenImage = NSImage(cgImage: frozenImage, size: frameRect.size)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
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

        drawFrozenScreen()
        NSColor.black.withAlphaComponent(0.34).setFill()
        bounds.fill()

        guard let selection = selectionRect,
              selection.width > 0,
              selection.height > 0 else {
            drawCaptureHint()
            drawCrosshairIfNeeded()
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        drawFrozenScreen()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.ttsAccent.withAlphaComponent(0.07).setFill()
        selection.fill()
        drawSelectionBorder(in: selection)
        drawSelectionSize(for: selection)
        drawCrosshairIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        updateCrosshair(at: point)
        startPoint = point
        currentPoint = point
        lastDragPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
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
            currentPoint = clampedPoint(convert(event.locationInWindow, from: nil))
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

    private func drawFrozenScreen() {
        frozenImage.draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func drawCaptureHint() {
        let text = "拖动选择截图区域  ·  Esc 取消  ·  按住空格移动选区"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96)
        ]
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributedText.size()
        let horizontalPadding: CGFloat = 14
        let verticalPadding: CGFloat = 8
        let hintSize = CGSize(
            width: textSize.width + horizontalPadding * 2,
            height: textSize.height + verticalPadding * 2
        )
        let hintRect = CGRect(
            x: bounds.midX - hintSize.width / 2,
            y: bounds.maxY - hintSize.height - 28,
            width: hintSize.width,
            height: hintSize.height
        )

        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(
            roundedRect: hintRect,
            xRadius: hintRect.height / 2,
            yRadius: hintRect.height / 2
        ).fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        let outline = NSBezierPath(
            roundedRect: hintRect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: hintRect.height / 2,
            yRadius: hintRect.height / 2
        )
        outline.lineWidth = 1
        outline.stroke()
        attributedText.draw(at: CGPoint(
            x: hintRect.minX + horizontalPadding,
            y: hintRect.minY + verticalPadding
        ))
    }

    private func drawSelectionBorder(in selection: CGRect) {
        NSColor.black.withAlphaComponent(0.36).setStroke()
        let outerOutline = NSBezierPath(rect: selection)
        outerOutline.lineWidth = 5
        outerOutline.stroke()

        NSColor.ttsSelectionAccent.setStroke()
        let accentOutline = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
        accentOutline.lineWidth = 2.5
        accentOutline.stroke()

        let handleSize: CGFloat = 7
        let handlePoints = [
            CGPoint(x: selection.minX, y: selection.minY),
            CGPoint(x: selection.maxX, y: selection.minY),
            CGPoint(x: selection.minX, y: selection.maxY),
            CGPoint(x: selection.maxX, y: selection.maxY)
        ]
        for point in handlePoints {
            let handleRect = CGRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            NSColor.ttsSelectionAccent.setFill()
            NSBezierPath(ovalIn: handleRect).fill()
            NSColor.white.setStroke()
            let handleOutline = NSBezierPath(ovalIn: handleRect.insetBy(dx: 0.75, dy: 0.75))
            handleOutline.lineWidth = 1.5
            handleOutline.stroke()
        }
    }

    private func drawSelectionSize(for selection: CGRect) {
        let width = max(1, Int(selection.width.rounded()))
        let height = max(1, Int(selection.height.rounded()))
        let attributedText = NSAttributedString(
            string: "\(width) × \(height)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        let textSize = attributedText.size()
        let horizontalPadding: CGFloat = 9
        let verticalPadding: CGFloat = 5
        let badgeSize = CGSize(
            width: textSize.width + horizontalPadding * 2,
            height: textSize.height + verticalPadding * 2
        )
        let x = min(
            max(selection.minX, bounds.minX + 8),
            bounds.maxX - badgeSize.width - 8
        )
        let preferredY = selection.maxY + 8
        let y = preferredY + badgeSize.height <= bounds.maxY - 8
            ? preferredY
            : max(bounds.minY + 8, selection.maxY - badgeSize.height - 8)
        let badgeRect = CGRect(origin: CGPoint(x: x, y: y), size: badgeSize)

        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(
            roundedRect: badgeRect,
            xRadius: 7,
            yRadius: 7
        ).fill()
        NSColor.ttsSelectionAccent.setStroke()
        let badgeOutline = NSBezierPath(
            roundedRect: badgeRect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 6.5,
            yRadius: 6.5
        )
        badgeOutline.lineWidth = 1
        badgeOutline.stroke()
        attributedText.draw(at: CGPoint(
            x: badgeRect.minX + horizontalPadding,
            y: badgeRect.minY + verticalPadding
        ))
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
        NSColor.ttsSelectionAccent.setStroke()
        accentPath.stroke()
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
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

@MainActor
final class ScreenshotAnnotationWindow: NSPanel {
    var onCopiedImage: ((CGImage, CGSize, CGRect) -> Void)?
    var onCopyFailed: (() -> Void)?
    var onCancelled: (() -> Void)?

    private let editorView: ScreenshotAnnotationView
    private let toolbarPanel: ScreenshotAnnotationToolbarPanel
    private let frozenImage: CGImage
    private let sourceScreenFrame: CGRect
    private var shieldWindows: [ScreenshotAnnotationShieldWindow] = []

    init(
        image: CGImage,
        selectionRect: CGRect,
        frozenImage: CGImage,
        screenFrame: CGRect
    ) {
        editorView = ScreenshotAnnotationView(
            image: image,
            logicalSize: selectionRect.size
        )
        toolbarPanel = ScreenshotAnnotationToolbarPanel()
        self.frozenImage = frozenImage
        sourceScreenFrame = screenFrame.standardized
        super.init(
            contentRect: selectionRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        contentView = editorView
        isOpaque = true
        backgroundColor = .black
        hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false

        for screen in NSScreen.screens {
            let screenSnapshot = screen.frame.standardized == sourceScreenFrame
                ? frozenImage
                : nil
            let shieldWindow = ScreenshotAnnotationShieldWindow(
                screen: screen,
                frozenImage: screenSnapshot
            )
            shieldWindow.onCancelled = { [weak self] in
                self?.onCancelled?()
            }
            shieldWindows.append(shieldWindow)
        }

        editorView.onHistoryChanged = { [weak toolbarPanel] canUndo in
            toolbarPanel?.setUndoEnabled(canUndo)
        }
        editorView.onMoveRequested = { [weak self] delta in
            self?.moveSelection(by: delta)
        }
        editorView.onResizeRequested = { [weak self] edges, delta in
            self?.resizeSelection(edges: edges, by: delta)
        }
        editorView.onCopyRequested = { [weak self] in
            self?.copyResult()
        }
        editorView.onCancelRequested = { [weak self] in
            self?.onCancelled?()
        }
        toolbarPanel.onToolSelected = { [weak editorView] tool in
            editorView?.setTool(tool)
        }
        toolbarPanel.onUndo = { [weak editorView] in
            editorView?.undo()
        }
        toolbarPanel.onCancel = { [weak self] in
            self?.onCancelled?()
        }
        toolbarPanel.onCopy = { [weak self] in
            self?.copyResult()
        }

        addChildWindow(toolbarPanel, ordered: .above)
        positionToolbar()
    }

    override var canBecomeKey: Bool {
        true
    }

    override func cancelOperation(_ sender: Any?) {
        onCancelled?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onCancelled?()
            return
        }
        super.sendEvent(event)
    }

    override func orderFrontRegardless() {
        positionToolbar()
        shieldWindows.forEach { $0.orderFrontRegardless() }
        super.orderFrontRegardless()
        toolbarPanel.orderFrontRegardless()
        makeKey()
        makeFirstResponder(editorView)
    }

    func dismissEditor() {
        removeChildWindow(toolbarPanel)
        toolbarPanel.orderOut(nil)
        orderOut(nil)
        shieldWindows.forEach { $0.orderOut(nil) }
        shieldWindows.removeAll()
    }

    private func copyResult() {
        guard let image = editorView.renderedImage() else {
            onCopyFailed?()
            return
        }
        onCopiedImage?(image, editorView.logicalSize, frame)
    }

    private func moveSelection(by delta: CGPoint) {
        let nextFrame = ScreenshotCaptureController.movedSelectionRect(
            frame,
            by: delta,
            within: sourceScreenFrame
        )
        guard nextFrame.origin != frame.origin,
              let croppedImage = ScreenshotCaptureController.croppedFrozenScreenshot(
                  frozenImage,
                  screenFrame: sourceScreenFrame,
                  selectionRect: nextFrame
              ),
              editorView.replaceBaseImage(
                  croppedImage,
                  logicalSize: nextFrame.size
              ) else {
            return
        }

        setFrameOrigin(nextFrame.origin)
        positionToolbar()
    }

    private func resizeSelection(
        edges: ScreenshotSelectionResizeEdges,
        by delta: CGPoint
    ) {
        let nextFrame = ScreenshotCaptureController.resizedSelectionRect(
            frame,
            edges: edges,
            by: delta,
            within: sourceScreenFrame
        )
        guard nextFrame != frame,
              let croppedImage = ScreenshotCaptureController.croppedFrozenScreenshot(
                  frozenImage,
                  screenFrame: sourceScreenFrame,
                  selectionRect: nextFrame
              ),
              editorView.replaceBaseImage(
                  croppedImage,
                  logicalSize: nextFrame.size
              ) else {
            return
        }

        setFrame(nextFrame, display: true)
        positionToolbar()
    }

    private func positionToolbar() {
        let toolbarSize = ScreenshotAnnotationToolbarPanel.preferredSize
        let targetScreen = NSScreen.screens.max { first, second in
            intersectionArea(first.frame, frame) < intersectionArea(second.frame, frame)
        }
        let visibleFrame = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let edgeInset: CGFloat = 10
        let gap: CGFloat = 10
        let minimumX = visibleFrame.minX + edgeInset
        let maximumX = visibleFrame.maxX - toolbarSize.width - edgeInset
        let x = maximumX >= minimumX
            ? min(max(frame.maxX - toolbarSize.width, minimumX), maximumX)
            : visibleFrame.midX - toolbarSize.width / 2

        let preferredBelow = frame.minY - toolbarSize.height - gap
        let minimumY = visibleFrame.minY + edgeInset
        let maximumY = visibleFrame.maxY - toolbarSize.height - edgeInset
        let y: CGFloat
        if preferredBelow >= minimumY {
            y = preferredBelow
        } else {
            let insideBottom = max(frame.minY + gap, minimumY)
            let fitsInsideSelection = frame.height >= toolbarSize.height + gap * 2 &&
                insideBottom + toolbarSize.height <= min(frame.maxY - gap, maximumY + toolbarSize.height)
            if fitsInsideSelection {
                y = insideBottom
            } else {
                y = min(max(frame.maxY + gap, minimumY), maximumY)
            }
        }

        toolbarPanel.setFrame(
            CGRect(origin: CGPoint(x: x, y: y), size: toolbarSize),
            display: false
        )
    }

    private func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else {
            return 0
        }
        return intersection.width * intersection.height
    }
}

@MainActor
private final class ScreenshotAnnotationShieldWindow: NSPanel {
    var onCancelled: (() -> Void)? {
        didSet {
            shieldView.onCancelled = onCancelled
        }
    }

    private let shieldView: ScreenshotAnnotationShieldView

    init(screen: NSScreen, frozenImage: CGImage?) {
        shieldView = ScreenshotAnnotationShieldView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            frozenImage: frozenImage
        )
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentView = shieldView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool {
        false
    }
}

@MainActor
private final class ScreenshotAnnotationShieldView: NSView {
    var onCancelled: (() -> Void)?

    private let frozenImage: NSImage?

    init(frame frameRect: NSRect, frozenImage: CGImage?) {
        self.frozenImage = frozenImage.map { image in
            NSImage(cgImage: image, size: frameRect.size)
        }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        frozenImage?.draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
        onCancelled?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancelled?()
    }

    override func otherMouseDown(with event: NSEvent) {
        onCancelled?()
    }
}

@MainActor
private final class ScreenshotAnnotationToolbarPanel: NSPanel {
    static let preferredSize = NSSize(width: 634, height: 60)
    private static let toolButtonWidth: CGFloat = 72
    private static let buttonHeight: CGFloat = 36

    var onToolSelected: ((ScreenshotAnnotationTool) -> Void)?
    var onUndo: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?

    private var toolButtons: [ScreenshotAnnotationTool: ScreenshotAnnotationToolButton] = [:]
    private let undoButton = ScreenshotToolbarButton(
        title: "",
        kind: .icon,
        target: nil,
        action: nil
    )

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: Self.preferredSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true

        let effectView = TTSGlassEffectView()
        effectView.ttsCornerRadius = 14
        contentView = effectView

        let move = makeToolButton(
            title: "移动",
            symbolName: "hand.draw",
            tool: .move
        )
        move.toolTip = "拖动选区；拖动边缘可调整尺寸"
        let rectangle = makeToolButton(
            title: "矩形",
            symbolName: "rectangle",
            tool: .rectangle
        )
        let arrow = makeToolButton(
            title: "箭头",
            symbolName: "arrow.up.right",
            tool: .arrow
        )
        let text = makeToolButton(
            title: "文字",
            symbolName: "textformat",
            tool: .text
        )
        let mosaic = makeToolButton(
            title: "马赛克",
            symbolName: "square.grid.3x3.fill",
            tool: .mosaic
        )
        let toolStack = NSStackView(views: [move, rectangle, arrow, text, mosaic])
        toolStack.orientation = .horizontal
        toolStack.alignment = .centerY
        toolStack.spacing = 4

        configureIconButton(
            undoButton,
            symbolName: "arrow.uturn.backward",
            toolTip: "撤销（⌘Z）",
            width: 38
        )
        undoButton.target = self
        undoButton.action = #selector(undoPressed)
        undoButton.isEnabled = false

        let cancel = ScreenshotToolbarButton(
            title: "取消",
            kind: .secondary,
            target: self,
            action: #selector(cancelPressed)
        )
        configureActionButton(
            cancel,
            symbolName: "xmark",
            width: 66,
            isPrimary: false
        )
        cancel.toolTip = "取消截图（Esc）"

        let copy = ScreenshotToolbarButton(
            title: "复制",
            kind: .primary,
            target: self,
            action: #selector(copyPressed)
        )
        configureActionButton(
            copy,
            symbolName: "doc.on.doc.fill",
            width: 78,
            isPrimary: true
        )
        copy.keyEquivalent = "\r"
        copy.toolTip = "复制到剪贴板（Return）"

        let stack = NSStackView(views: [
            toolStack,
            makeSeparator(),
            undoButton,
            makeSeparator(),
            cancel,
            copy
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -11),
            stack.centerYAnchor.constraint(equalTo: effectView.centerYAnchor)
        ])

        updateSelectedTool(.move)
    }

    override var canBecomeKey: Bool {
        true
    }

    func setUndoEnabled(_ enabled: Bool) {
        undoButton.isEnabled = enabled
    }

    private func makeToolButton(
        title: String,
        symbolName: String,
        tool: ScreenshotAnnotationTool
    ) -> ScreenshotAnnotationToolButton {
        let button = ScreenshotAnnotationToolButton(
            title: title,
            tool: tool,
            target: self,
            action: #selector(toolPressed(_:))
        )
        button.setButtonType(.toggle)
        button.isBordered = false
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.image = symbolImage(named: symbolName, description: title)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleNone
        button.imageHugsTitle = true
        button.alignment = .center
        button.toolTip = title
        constrain(button, width: Self.toolButtonWidth)
        toolButtons[tool] = button
        return button
    }

    private func configureIconButton(
        _ button: ScreenshotToolbarButton,
        symbolName: String,
        toolTip: String,
        width: CGFloat
    ) {
        button.isBordered = false
        button.controlSize = .regular
        button.image = symbolImage(named: symbolName, description: toolTip)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.alignment = .center
        button.toolTip = toolTip
        constrain(button, width: width)
    }

    private func configureActionButton(
        _ button: ScreenshotToolbarButton,
        symbolName: String,
        width: CGFloat,
        isPrimary: Bool
    ) {
        button.isBordered = false
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: isPrimary ? .semibold : .medium)
        button.image = symbolImage(named: symbolName, description: button.title)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleNone
        button.imageHugsTitle = true
        button.alignment = .center
        button.refreshToolbarAppearance()
        constrain(button, width: width)
    }

    private func constrain(_ button: NSButton, width: CGFloat) {
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: Self.buttonHeight)
        ])
    }

    private func makeSeparator() -> NSView {
        let separator = ScreenshotToolbarSeparator()
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 24)
        ])
        return separator
    }

    private func symbolImage(named name: String, description: String) -> NSImage? {
        guard let symbol = NSImage(
            systemSymbolName: name,
            accessibilityDescription: description
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) else {
            return nil
        }

        let canvasSize = NSSize(width: 18, height: 18)
        let canvas = NSImage(size: canvasSize, flipped: false) { rect in
            let symbolSize = symbol.size
            guard symbolSize.width > 0, symbolSize.height > 0 else { return false }
            let scale = min(16 / symbolSize.width, 16 / symbolSize.height, 1)
            let drawSize = NSSize(
                width: symbolSize.width * scale,
                height: symbolSize.height * scale
            )
            let drawRect = NSRect(
                x: rect.midX - drawSize.width / 2,
                y: rect.midY - drawSize.height / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            symbol.draw(
                in: drawRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        canvas.isTemplate = true
        return canvas
    }

    private func updateSelectedTool(_ tool: ScreenshotAnnotationTool) {
        for (candidate, button) in toolButtons {
            let isSelected = candidate == tool
            button.state = isSelected ? .on : .off
            button.isToolbarSelected = isSelected
        }
    }

    @objc private func toolPressed(_ sender: ScreenshotAnnotationToolButton) {
        updateSelectedTool(sender.tool)
        onToolSelected?(sender.tool)
    }

    @objc private func undoPressed() {
        onUndo?()
    }

    @objc private func cancelPressed() {
        onCancel?()
    }

    @objc private func copyPressed() {
        onCopy?()
    }
}

private enum ScreenshotToolbarButtonKind: Equatable {
    case tool
    case icon
    case secondary
    case primary
}

private class ScreenshotToolbarButton: NSButton {
    let kind: ScreenshotToolbarButtonKind
    var isToolbarSelected = false {
        didSet { refreshToolbarAppearance() }
    }

    init(
        title: String,
        kind: ScreenshotToolbarButtonKind,
        target: AnyObject?,
        action: Selector?
    ) {
        self.kind = kind
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        refreshToolbarAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEnabled: Bool {
        didSet { refreshToolbarAppearance() }
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        refreshToolbarAppearance(isPressed: flag)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshToolbarAppearance()
    }

    func refreshToolbarAppearance(isPressed: Bool = false) {
        guard let layer else { return }
        let usesAccent = kind == .primary || isToolbarSelected
        let backgroundColor: NSColor
        let borderColor: NSColor
        let foregroundColor: NSColor

        if usesAccent {
            backgroundColor = NSColor.ttsAccent.withAlphaComponent(isPressed ? 0.78 : 1)
            borderColor = .ttsAccentStrong
            foregroundColor = .white
        } else {
            switch kind {
            case .tool:
                backgroundColor = isPressed ? .ttsToolbarControl : .clear
                borderColor = .clear
            case .icon, .secondary:
                backgroundColor = isPressed
                    ? NSColor.ttsAccent.withAlphaComponent(0.14)
                    : .ttsToolbarControl
                borderColor = .ttsToolbarDivider
            case .primary:
                backgroundColor = .ttsAccent
                borderColor = .ttsAccentStrong
            }
            foregroundColor = .labelColor
        }

        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        layer.backgroundColor = backgroundColor.cgColor
        layer.borderColor = borderColor.cgColor
        layer.borderWidth = usesAccent || kind == .secondary || kind == .icon ? 1 : 0
        alphaValue = isEnabled ? 1 : 0.34
        contentTintColor = foregroundColor
        if !title.isEmpty {
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: foregroundColor
                ]
            )
        }
    }
}

private final class ScreenshotToolbarSeparator: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = NSColor.ttsToolbarDivider.cgColor
        layer?.cornerRadius = 0.5
    }
}

private final class ScreenshotAnnotationToolButton: ScreenshotToolbarButton {
    let tool: ScreenshotAnnotationTool

    init(
        title: String,
        tool: ScreenshotAnnotationTool,
        target: AnyObject?,
        action: Selector?
    ) {
        self.tool = tool
        super.init(title: title, kind: .tool, target: target, action: action)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class ScreenshotAnnotationView: NSView {
    var onHistoryChanged: ((Bool) -> Void)?
    var onMoveRequested: ((CGPoint) -> Void)?
    var onResizeRequested: ((ScreenshotSelectionResizeEdges, CGPoint) -> Void)?
    var onCopyRequested: (() -> Void)?
    var onCancelRequested: (() -> Void)?

    private var baseImage: CGImage
    private(set) var logicalSize: CGSize
    private var previewImage: CGImage
    private var document = ScreenshotAnnotationDocument()
    private var selectedTool: ScreenshotAnnotationTool = .move
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var selectionDragLastGlobalPoint: CGPoint?
    private var activeResizeEdges: ScreenshotSelectionResizeEdges = []
    private var isMovingSelection = false
    private var longPressTask: Task<Void, Never>?
    private var textEditor: NSTextField?
    private var textOrigin: CGPoint?

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor = selectedTool == .move ? .openHand : .crosshair
        addCursorRect(bounds, cursor: cursor)
        guard selectedTool == .move else {
            return
        }

        let hitWidth = resizeHandleHitWidth
        addCursorRect(
            CGRect(x: bounds.minX, y: bounds.minY, width: hitWidth, height: bounds.height),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            CGRect(x: bounds.maxX - hitWidth, y: bounds.minY, width: hitWidth, height: bounds.height),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: hitWidth),
            cursor: .resizeUpDown
        )
        addCursorRect(
            CGRect(x: bounds.minX, y: bounds.maxY - hitWidth, width: bounds.width, height: hitWidth),
            cursor: .resizeUpDown
        )
    }

    init(image: CGImage, logicalSize: CGSize) {
        baseImage = image
        self.logicalSize = logicalSize
        previewImage = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let image = NSImage(cgImage: previewImage, size: bounds.size)
        image.draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        drawDraftIfNeeded()
        NSColor.ttsSelectionAccent.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()
        if selectedTool == .move {
            drawResizeHandles()
            drawSelectionSize()
        }
    }

    override func mouseDown(with event: NSEvent) {
        commitPendingText()
        finishSelectionDrag()
        let point = clampedPoint(convert(event.locationInWindow, from: nil))

        if selectedTool == .move {
            let resizeEdges = resizeEdges(at: point)
            if resizeEdges.isEmpty {
                beginSelectionMove()
            } else {
                beginSelectionResize(edges: resizeEdges)
            }
            return
        }

        if selectedTool == .text {
            beginTextEntry(at: point)
            return
        }

        dragStart = point
        dragCurrent = point
        scheduleLongPressMove()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if isMovingSelection || !activeResizeEdges.isEmpty {
            updateSelectionDrag()
            return
        }

        guard let dragStart else {
            return
        }
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        if hypot(point.x - dragStart.x, point.y - dragStart.y) >= 3 {
            cancelLongPressMove()
        }
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isMovingSelection || !activeResizeEdges.isEmpty {
            finishSelectionDrag()
            return
        }

        cancelLongPressMove()
        guard let dragStart else {
            return
        }
        let end = clampedPoint(convert(event.locationInWindow, from: nil))
        self.dragStart = nil
        dragCurrent = nil

        guard hypot(end.x - dragStart.x, end.y - dragStart.y) >= 3 else {
            needsDisplay = true
            return
        }

        let normalizedStart = normalizedPoint(dragStart)
        let normalizedEnd = normalizedPoint(end)
        switch selectedTool {
        case .move:
            break
        case .rectangle:
            document.append(.rectangle(start: normalizedStart, end: normalizedEnd))
        case .arrow:
            document.append(.arrow(start: normalizedStart, end: normalizedEnd))
        case .mosaic:
            document.append(.mosaic(start: normalizedStart, end: normalizedEnd))
        case .text:
            break
        }
        refreshPreview()
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancelRequested?()
    }

    override func otherMouseDown(with event: NSEvent) {
        onCancelRequested?()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 6 {
            undo()
        } else if event.keyCode == 53 {
            onCancelRequested?()
        } else if event.keyCode == 36 || event.keyCode == 76 {
            onCopyRequested?()
        } else if selectedTool == .move,
                  let delta = keyboardMoveDelta(for: event) {
            onMoveRequested?(delta)
        } else {
            super.keyDown(with: event)
        }
    }

    func setTool(_ tool: ScreenshotAnnotationTool) {
        commitPendingText()
        cancelLongPressMove()
        finishSelectionDrag()
        selectedTool = tool
        dragStart = nil
        dragCurrent = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func undo() {
        if textEditor != nil {
            discardPendingText()
            return
        }
        guard document.undo() != nil else {
            return
        }
        refreshPreview()
    }

    func replaceBaseImage(
        _ image: CGImage,
        logicalSize: CGSize
    ) -> Bool {
        guard logicalSize.width.isFinite,
              logicalSize.height.isFinite,
              logicalSize.width > 0,
              logicalSize.height > 0 else {
            return false
        }
        commitPendingText()
        baseImage = image
        self.logicalSize = logicalSize
        refreshPreview()
        window?.invalidateCursorRects(for: self)
        return true
    }

    func renderedImage() -> CGImage? {
        commitPendingText()
        return ScreenshotAnnotationRenderer.render(
            baseImage: baseImage,
            annotations: document.annotations,
            logicalSize: logicalSize
        )
    }

    private var resizeHandleHitWidth: CGFloat {
        min(12, max(6, min(bounds.width, bounds.height) / 3))
    }

    private func resizeEdges(at point: CGPoint) -> ScreenshotSelectionResizeEdges {
        let hitWidth = resizeHandleHitWidth
        var edges: ScreenshotSelectionResizeEdges = []
        if point.x <= bounds.minX + hitWidth {
            edges.insert(.minX)
        } else if point.x >= bounds.maxX - hitWidth {
            edges.insert(.maxX)
        }
        if point.y <= bounds.minY + hitWidth {
            edges.insert(.maxY)
        } else if point.y >= bounds.maxY - hitWidth {
            edges.insert(.minY)
        }
        return edges
    }

    private func beginSelectionMove() {
        cancelLongPressMove()
        dragStart = nil
        dragCurrent = nil
        activeResizeEdges = []
        isMovingSelection = true
        selectionDragLastGlobalPoint = NSEvent.mouseLocation
        NSCursor.closedHand.set()
    }

    private func beginSelectionResize(edges: ScreenshotSelectionResizeEdges) {
        cancelLongPressMove()
        dragStart = nil
        dragCurrent = nil
        activeResizeEdges = edges
        isMovingSelection = false
        selectionDragLastGlobalPoint = NSEvent.mouseLocation
    }

    private func updateSelectionDrag() {
        let globalPoint = NSEvent.mouseLocation
        guard let previousPoint = selectionDragLastGlobalPoint else {
            selectionDragLastGlobalPoint = globalPoint
            return
        }
        let delta = CGPoint(
            x: globalPoint.x - previousPoint.x,
            y: globalPoint.y - previousPoint.y
        )
        guard delta != .zero else {
            return
        }

        selectionDragLastGlobalPoint = globalPoint
        if activeResizeEdges.isEmpty {
            onMoveRequested?(delta)
        } else {
            onResizeRequested?(activeResizeEdges, delta)
        }
    }

    private func finishSelectionDrag() {
        cancelLongPressMove()
        isMovingSelection = false
        activeResizeEdges = []
        selectionDragLastGlobalPoint = nil
        let cursor: NSCursor = selectedTool == .move ? .openHand : .crosshair
        cursor.set()
    }

    private func scheduleLongPressMove() {
        cancelLongPressMove()
        longPressTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 320_000_000)
            } catch {
                return
            }
            guard let self, self.dragStart != nil else {
                return
            }
            self.beginSelectionMove()
            self.needsDisplay = true
        }
    }

    private func cancelLongPressMove() {
        longPressTask?.cancel()
        longPressTask = nil
    }

    private func keyboardMoveDelta(for event: NSEvent) -> CGPoint? {
        let distance: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123:
            return CGPoint(x: -distance, y: 0)
        case 124:
            return CGPoint(x: distance, y: 0)
        case 125:
            return CGPoint(x: 0, y: -distance)
        case 126:
            return CGPoint(x: 0, y: distance)
        default:
            return nil
        }
    }

    private func beginTextEntry(at point: CGPoint) {
        discardPendingText()
        let field = NSTextField()
        field.placeholderString = "输入文字后按回车"
        field.font = .systemFont(ofSize: 18, weight: .semibold)
        field.textColor = .white
        field.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.target = self
        field.action = #selector(commitTextEditor(_:))

        let horizontalInset = min(8, bounds.width / 4)
        let verticalInset = min(8, bounds.height / 4)
        let availableWidth = max(0, bounds.width - horizontalInset * 2)
        let availableHeight = max(0, bounds.height - verticalInset * 2)
        guard availableWidth >= 44, availableHeight >= 20 else {
            NSSound.beep()
            return
        }
        let width = min(240, availableWidth)
        let height = min(28, availableHeight)
        let origin = CGPoint(
            x: min(
                max(point.x, horizontalInset),
                bounds.maxX - width - horizontalInset
            ),
            y: min(
                max(point.y, verticalInset),
                bounds.maxY - height - verticalInset
            )
        )
        field.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        addSubview(field)
        textEditor = field
        textOrigin = origin
        window?.makeFirstResponder(field)
    }

    @objc private func commitTextEditor(_ sender: Any?) {
        commitPendingText()
        window?.makeFirstResponder(self)
    }

    private func commitPendingText() {
        guard let field = textEditor else {
            return
        }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = textOrigin ?? field.frame.origin
        field.removeFromSuperview()
        textEditor = nil
        textOrigin = nil

        guard !value.isEmpty else {
            return
        }
        document.append(
            .text(
                value: value,
                origin: normalizedPoint(origin),
                fontScale: 18 / max(bounds.height, 1)
            )
        )
        refreshPreview()
    }

    private func discardPendingText() {
        textEditor?.removeFromSuperview()
        textEditor = nil
        textOrigin = nil
        window?.makeFirstResponder(self)
    }

    private func refreshPreview() {
        previewImage = ScreenshotAnnotationRenderer.render(
            baseImage: baseImage,
            annotations: document.annotations,
            logicalSize: logicalSize
        ) ?? baseImage
        onHistoryChanged?(document.canUndo)
        needsDisplay = true
    }

    private func drawSelectionSize() {
        let width = max(1, Int(logicalSize.width.rounded()))
        let height = max(1, Int(logicalSize.height.rounded()))
        let text = NSAttributedString(
            string: "\(width) × \(height)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        let textSize = text.size()
        let badgeSize = CGSize(width: textSize.width + 16, height: textSize.height + 8)
        guard bounds.width >= badgeSize.width + 12,
              bounds.height >= badgeSize.height + 12 else {
            return
        }
        let badgeRect = CGRect(
            x: bounds.minX + 7,
            y: bounds.minY + 7,
            width: badgeSize.width,
            height: badgeSize.height
        )
        NSColor.black.withAlphaComponent(0.74).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: badgeRect.minX + 8, y: badgeRect.minY + 4))
    }

    private func drawResizeHandles() {
        let handleSize: CGFloat = 7
        let inset = handleSize / 2
        let minX = bounds.minX + inset
        let maxX = bounds.maxX - inset
        let minY = bounds.minY + inset
        let maxY = bounds.maxY - inset
        let points = [
            CGPoint(x: minX, y: minY),
            CGPoint(x: bounds.midX, y: minY),
            CGPoint(x: maxX, y: minY),
            CGPoint(x: minX, y: bounds.midY),
            CGPoint(x: maxX, y: bounds.midY),
            CGPoint(x: minX, y: maxY),
            CGPoint(x: bounds.midX, y: maxY),
            CGPoint(x: maxX, y: maxY)
        ]

        for point in points {
            let handleRect = CGRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            NSColor.ttsSelectionAccent.setFill()
            NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2).fill()
            NSColor.white.setStroke()
            let outline = NSBezierPath(
                roundedRect: handleRect.insetBy(dx: 0.75, dy: 0.75),
                xRadius: 1.5,
                yRadius: 1.5
            )
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }

    private func drawDraftIfNeeded() {
        guard let start = dragStart, let end = dragCurrent else {
            return
        }

        switch selectedTool {
        case .move:
            break
        case .rectangle:
            let rect = rect(from: start, to: end)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 3
            NSColor.systemRed.setStroke()
            path.stroke()
        case .arrow:
            drawDraftArrow(from: start, to: end)
        case .mosaic:
            drawMosaicDraft(in: rect(from: start, to: end))
        case .text:
            break
        }
    }

    private func drawDraftArrow(from start: CGPoint, to end: CGPoint) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = 3
        path.lineCapStyle = .round
        NSColor.systemRed.setStroke()
        path.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 14
        let wing = CGFloat.pi / 7
        let head = NSBezierPath()
        head.move(to: CGPoint(
            x: end.x - length * cos(angle - wing),
            y: end.y - length * sin(angle - wing)
        ))
        head.line(to: end)
        head.line(to: CGPoint(
            x: end.x - length * cos(angle + wing),
            y: end.y - length * sin(angle + wing)
        ))
        head.lineWidth = 3
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.stroke()
    }

    private func drawMosaicDraft(in rect: CGRect) {
        NSColor.white.withAlphaComponent(0.28).setFill()
        rect.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let grid = NSBezierPath()
        let step: CGFloat = 10
        var x = rect.minX
        while x <= rect.maxX {
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.line(to: CGPoint(x: x, y: rect.maxY))
            x += step
        }
        var y = rect.minY
        while y <= rect.maxY {
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.line(to: CGPoint(x: rect.maxX, y: y))
            y += step
        }
        grid.lineWidth = 1
        grid.stroke()
    }

    private func normalizedPoint(_ point: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        return CGPoint(
            x: min(max(point.x / bounds.width, 0), 1),
            y: min(max(point.y / bounds.height, 0), 1)
        )
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        )
    }
}
