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

@MainActor
final class ScreenshotAnnotationWindow: NSPanel {
    var onCopiedImage: ((CGImage, CGSize) -> Void)?
    var onCopyFailed: (() -> Void)?
    var onCancelled: (() -> Void)?

    private let editorView: ScreenshotAnnotationView
    private let toolbarPanel: ScreenshotAnnotationToolbarPanel
    private var shieldWindows: [ScreenshotAnnotationShieldWindow] = []

    init(image: CGImage, selectionRect: CGRect) {
        editorView = ScreenshotAnnotationView(
            image: image,
            logicalSize: selectionRect.size
        )
        toolbarPanel = ScreenshotAnnotationToolbarPanel()
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
            let shieldWindow = ScreenshotAnnotationShieldWindow(screen: screen)
            shieldWindow.onCancelled = { [weak self] in
                self?.onCancelled?()
            }
            shieldWindows.append(shieldWindow)
        }

        editorView.onHistoryChanged = { [weak toolbarPanel] canUndo in
            toolbarPanel?.setUndoEnabled(canUndo)
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
        onCopiedImage?(image, editorView.logicalSize)
    }

    private func positionToolbar() {
        let toolbarSize = ScreenshotAnnotationToolbarPanel.preferredSize
        let targetScreen = NSScreen.screens.max { first, second in
            intersectionArea(first.frame, frame) < intersectionArea(second.frame, frame)
        }
        let visibleFrame = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let x = min(
            max(frame.maxX - toolbarSize.width, visibleFrame.minX + 8),
            visibleFrame.maxX - toolbarSize.width - 8
        )
        let preferredBelow = frame.minY - toolbarSize.height - 8
        let y: CGFloat
        if preferredBelow >= visibleFrame.minY + 8 {
            y = preferredBelow
        } else {
            y = min(
                frame.maxY + 8,
                visibleFrame.maxY - toolbarSize.height - 8
            )
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

    init(screen: NSScreen) {
        shieldView = ScreenshotAnnotationShieldView(frame: screen.frame)
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
    static let preferredSize = NSSize(width: 452, height: 48)

    var onToolSelected: ((ScreenshotAnnotationTool) -> Void)?
    var onUndo: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?

    private var toolButtons: [ScreenshotAnnotationTool: NSButton] = [:]
    private let undoButton = NSButton(title: "撤销", target: nil, action: nil)

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

        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.masksToBounds = true
        contentView = effectView

        let rectangle = makeToolButton(title: "矩形", tool: .rectangle)
        let arrow = makeToolButton(title: "箭头", tool: .arrow)
        let text = makeToolButton(title: "文字", tool: .text)
        let mosaic = makeToolButton(title: "马赛克", tool: .mosaic)
        undoButton.target = self
        undoButton.action = #selector(undoPressed)
        undoButton.isEnabled = false
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelPressed))
        let copy = NSButton(title: "复制", target: self, action: #selector(copyPressed))
        copy.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            rectangle,
            arrow,
            text,
            mosaic,
            undoButton,
            cancel,
            copy
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -7)
        ])

        updateSelectedTool(.rectangle)
    }

    override var canBecomeKey: Bool {
        true
    }

    func setUndoEnabled(_ enabled: Bool) {
        undoButton.isEnabled = enabled
    }

    private func makeToolButton(
        title: String,
        tool: ScreenshotAnnotationTool
    ) -> NSButton {
        let button = ScreenshotAnnotationToolButton(
            title: title,
            tool: tool,
            target: self,
            action: #selector(toolPressed(_:))
        )
        button.setButtonType(.toggle)
        button.bezelStyle = .rounded
        toolButtons[tool] = button
        return button
    }

    private func updateSelectedTool(_ tool: ScreenshotAnnotationTool) {
        for (candidate, button) in toolButtons {
            button.state = candidate == tool ? .on : .off
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

private final class ScreenshotAnnotationToolButton: NSButton {
    let tool: ScreenshotAnnotationTool

    init(
        title: String,
        tool: ScreenshotAnnotationTool,
        target: AnyObject?,
        action: Selector?
    ) {
        self.tool = tool
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class ScreenshotAnnotationView: NSView {
    var onHistoryChanged: ((Bool) -> Void)?
    var onCopyRequested: (() -> Void)?
    var onCancelRequested: (() -> Void)?

    private let baseImage: CGImage
    let logicalSize: CGSize
    private var previewImage: CGImage
    private var document = ScreenshotAnnotationDocument()
    private var selectedTool: ScreenshotAnnotationTool = .rectangle
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var textEditor: NSTextField?
    private var textOrigin: CGPoint?

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
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
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        commitPendingText()
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        if selectedTool == .text {
            beginTextEntry(at: point)
            return
        }

        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else {
            return
        }
        dragCurrent = clampedPoint(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
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
        } else {
            super.keyDown(with: event)
        }
    }

    func setTool(_ tool: ScreenshotAnnotationTool) {
        commitPendingText()
        selectedTool = tool
        dragStart = nil
        dragCurrent = nil
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

    func renderedImage() -> CGImage? {
        commitPendingText()
        return ScreenshotAnnotationRenderer.render(
            baseImage: baseImage,
            annotations: document.annotations,
            logicalSize: logicalSize
        )
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

    private func drawDraftIfNeeded() {
        guard let start = dragStart, let end = dragCurrent else {
            return
        }

        switch selectedTool {
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
