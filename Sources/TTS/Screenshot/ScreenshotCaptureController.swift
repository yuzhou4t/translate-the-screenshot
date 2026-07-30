import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotCaptureMode {
    case clipboard
    case translate
    case translateOverlay
    case translateOverlayAPI
    case translateOverlayLocal
    case ocr
    case silentOCR

    var coordinateTranslationEngine: ImageOverlayTranslationEngine? {
        switch self {
        case .translateOverlayAPI:
            .configuredProvider
        case .translateOverlayLocal:
            .appleLocal
        case .clipboard, .translate, .translateOverlay, .ocr, .silentOCR:
            nil
        }
    }

    var usesOverlayWindow: Bool {
        self == .translateOverlay || coordinateTranslationEngine != nil
    }
}

@MainActor
final class ScreenshotCaptureController {
    private let permissionManager: PermissionManager
    private let ocrService: OCRService
    private let ocrResultPanel: OCRResultPanel
    private let translationService: TranslationService
    private let floatingPanel: FloatingTranslatePanel
    private let toastPanel: ToastPanel
    private let clipboardToastPanel: ToastPanel
    private let imageOverlayTranslationWindowController: ImageOverlayTranslationWindowController
    private let providerRegistry: ProviderRegistry
    private let policyStore: VolcengineImageTranslationPolicyStore
    private let settingsWindowController: SettingsWindowController
    private var overlayWindows: [ScreenshotOverlayWindow] = []
    private var annotationWindow: ScreenshotAnnotationWindow?
    private var isCapturing = false
    private var didHideSystemCursor = false
    private var activeMode: ScreenshotCaptureMode = .translate
    private var activeProcessingTask: Task<Void, Never>?
    private var activeProcessingToken: UUID?
    private var activeProcessingMode: ScreenshotCaptureMode?
    private var activeProcessingAnchorPoint: NSPoint?

    init(
        permissionManager: PermissionManager,
        ocrService: OCRService,
        ocrResultPanel: OCRResultPanel,
        translationService: TranslationService,
        floatingPanel: FloatingTranslatePanel,
        toastPanel: ToastPanel,
        clipboardToastPanel: ToastPanel,
        imageOverlayTranslationWindowController: ImageOverlayTranslationWindowController,
        providerRegistry: ProviderRegistry,
        policyStore: VolcengineImageTranslationPolicyStore,
        settingsWindowController: SettingsWindowController
    ) {
        self.permissionManager = permissionManager
        self.ocrService = ocrService
        self.ocrResultPanel = ocrResultPanel
        self.translationService = translationService
        self.floatingPanel = floatingPanel
        self.toastPanel = toastPanel
        self.clipboardToastPanel = clipboardToastPanel
        self.imageOverlayTranslationWindowController = imageOverlayTranslationWindowController
        self.providerRegistry = providerRegistry
        self.policyStore = policyStore
        self.settingsWindowController = settingsWindowController
    }

    func startCapture(mode: ScreenshotCaptureMode) {
        guard !isCapturing else {
            return
        }

        if mode != .clipboard {
            cancelActiveProcessing(showFeedback: false)
        }
        if mode.usesOverlayWindow {
            imageOverlayTranslationWindowController.cancelCurrentWork()
        }

        if mode == .translateOverlay, !prepareVolcengineImageTranslation() {
            return
        }

        guard permissionManager.isScreenRecordingTrusted else {
            permissionManager.requestScreenRecordingIfNeeded()
            permissionManager.openScreenRecordingSettings()
            let feedbackPanel = mode == .clipboard ? clipboardToastPanel : toastPanel
            feedbackPanel.show("请允许 TTS 屏幕录制，授权后重启 TTS")
            print("screenshot cancelled: screen recording permission required")
            return
        }

        isCapturing = true
        activeMode = mode
        hideSystemCursor()
        overlayWindows = NSScreen.screens.map { screen in
            let window = ScreenshotOverlayWindow(screen: screen)
            window.onFinished = { [weak self, weak window] selectionRect in
                guard let window else {
                    self?.cancelCapture()
                    return
                }
                self?.finishCapture(
                    selectionRect: selectionRect,
                    belowWindowID: CGWindowID(window.windowNumber)
                )
            }
            window.onCancelled = { [weak self] in
                self?.cancelCapture()
            }
            return window
        }

        overlayWindows.forEach { $0.orderFrontRegardless() }
        overlayWindows.forEach { $0.updateCrosshair(globalPoint: NSEvent.mouseLocation) }
        overlayWindows.first?.makeKey()
    }

    private func prepareVolcengineImageTranslation() -> Bool {
        do {
            _ = try providerRegistry.makeVolcengineImageTranslationProvider()
        } catch {
            toastPanel.show("请先配置火山翻译的 AccessKey ID 与 Secret Access Key")
            NSApp.activate(ignoringOtherApps: true)
            settingsWindowController.show(
                tab: .translationService,
                providerID: .volcengine
            )
            return false
        }

        let usage = policyStore.snapshot
        guard usage.remainingCount > 0 else {
            toastPanel.show("火山图片翻译本月安全计数已达 \(usage.limit) 张上限；可使用 API 或 Apple 坐标翻译")
            return false
        }

        guard !policyStore.hasUploadConsent else {
            return true
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "启用火山图片翻译 Beta？"
        alert.informativeText = """
        从菜单或已配置的火山快捷键启动后，框选的完整截图会上传到火山引擎进行 OCR、翻译和整图回填。

        你只需同意一次；之后再次主动启动时会直接上传。每次提交前会同步火山账号当月图片用量，并与本机保守计数取较大值；免费 100 张用完后直接阻止。失败或超时也计入本机限额。
        """
        alert.addButton(withTitle: "同意并继续")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else {
            toastPanel.show("已取消；截图没有上传")
            return false
        }

        policyStore.grantUploadConsent()
        return true
    }

    func openImageFileOCR() {
        cancelActiveProcessing(showFeedback: false)

        let panel = NSOpenPanel()
        panel.title = "选择图片文件"
        panel.message = "选择一张图片进行 OCR 识别"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .png,
            .jpeg,
            UTType(filenameExtension: "jpg") ?? .jpeg,
            UTType(filenameExtension: "webp") ?? .image,
            UTType(filenameExtension: "heic") ?? .heic
        ]

        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let imageURL = panel.url else {
            return
        }

        let anchorPoint = NSEvent.mouseLocation
        ocrResultPanel.showLoading(
            near: anchorPoint,
            onCancel: { [weak self] in
                self?.cancelActiveWork()
            }
        )

        let taskToken = UUID()
        let task = Task { [ocrService, ocrResultPanel] in
            defer {
                Task { @MainActor [weak self] in
                    self?.finishActiveProcessingTask(ifMatches: taskToken)
                }
            }
            do {
                let result = try await ocrService.recognizeText(from: imageURL, mode: .accurate)
                try Task.checkCancellation()
                let plainText = result.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !plainText.isEmpty else {
                    throw ScreenshotCaptureError.noRecognizedText
                }

                await MainActor.run {
                    ocrResultPanel.showResult(result, imageURL: imageURL, near: anchorPoint)
                }
            } catch is CancellationError {
                await MainActor.run {
                    ocrResultPanel.hide()
                }
            } catch {
                await MainActor.run {
                    ocrResultPanel.showError(error.localizedDescription, near: anchorPoint)
                }
            }
        }
        beginActiveProcessingTask(
            task,
            token: taskToken,
            mode: .ocr,
            anchorPoint: anchorPoint
        )
    }

    func cancelActiveWork() {
        let hadProcessingTask = activeProcessingTask != nil
        let didCancel = cancelActiveProcessing(showFeedback: false)
        let didCancelWindow = hadProcessingTask
            ? false
            : imageOverlayTranslationWindowController.cancelCurrentWork()
        if didCancel || didCancelWindow {
            toastPanel.show("已停止当前截图任务")
        } else {
            toastPanel.show("当前没有正在运行的截图任务")
        }
    }

    private func finishCapture(
        selectionRect: CGRect,
        belowWindowID: CGWindowID
    ) {
        guard isCapturing else {
            return
        }

        let mode = activeMode

        guard selectionRect.width >= 2, selectionRect.height >= 2 else {
            closeOverlays()
            print("screenshot cancelled")
            return
        }

        do {
            let image = try captureScreenshot(
                selectionRect: selectionRect,
                belowWindowID: belowWindowID
            )
            closeOverlays()
            if mode == .clipboard {
                presentAnnotationEditor(
                    image: image,
                    selectionRect: selectionRect
                )
                return
            }

            let fileURL = try saveScreenshot(
                image: image,
                mode: mode
            )
            print("screenshot saved: \(fileURL.path)")
            handleScreenshot(
                imageURL: fileURL,
                near: NSPoint(x: selectionRect.maxX, y: selectionRect.maxY),
                mode: mode,
                captureDisplaySize: selectionRect.size
            )
        } catch {
            closeOverlays()
            if mode == .clipboard {
                clipboardToastPanel.show(
                    "截图失败：\(error.localizedDescription)",
                    near: NSPoint(x: selectionRect.maxX, y: selectionRect.maxY)
                )
            }
            print("screenshot failed: \(error.localizedDescription)")
        }
    }

    private func cancelCapture() {
        guard isCapturing else {
            return
        }

        if annotationWindow != nil {
            closeAnnotationEditor()
        } else {
            closeOverlays()
        }
        print("screenshot cancelled")
    }

    private func closeOverlays() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        showSystemCursorIfNeeded()
        isCapturing = false
    }

    private func hideSystemCursor() {
        guard !didHideSystemCursor else {
            return
        }

        NSCursor.hide()
        didHideSystemCursor = true
    }

    private func showSystemCursorIfNeeded() {
        guard didHideSystemCursor else {
            return
        }

        NSCursor.unhide()
        didHideSystemCursor = false
    }

    private func handleScreenshot(
        imageURL: URL,
        near point: NSPoint,
        mode: ScreenshotCaptureMode,
        captureDisplaySize: CGSize? = nil
    ) {
        if mode == .clipboard {
            return
        }

        if mode == .translateOverlay {
            do {
                let originalImage = try Self.loadImage(from: imageURL)
                imageOverlayTranslationWindowController.showVolcengineTranslation(
                    originalImage: originalImage,
                    imageURL: imageURL,
                    onUseLocalFallback: { [weak self] in
                        self?.handleScreenshot(
                            imageURL: imageURL,
                            near: point,
                            mode: .translateOverlayLocal,
                            captureDisplaySize: captureDisplaySize
                        )
                    }
                )
            } catch {
                imageOverlayTranslationWindowController.showError(error.localizedDescription)
            }
            return
        }

        let presentationID: UUID?
        switch mode {
        case .clipboard:
            presentationID = nil
        case .translate:
            presentationID = floatingPanel.showLoading(
                sourceText: "正在识别截图文字...",
                near: point,
                onCancel: { [weak self] in
                    self?.cancelActiveWork()
                }
            )
        case .translateOverlay:
            presentationID = nil
        case .translateOverlayAPI:
            presentationID = nil
            toastPanel.showLoading(
                "正在准备 API 高质量坐标翻译...",
                near: point,
                onCancel: { [weak self] in
                    self?.cancelActiveWork()
                }
            )
        case .translateOverlayLocal:
            presentationID = nil
            toastPanel.showLoading(
                "正在准备 Apple 本地坐标翻译...",
                near: point,
                onCancel: { [weak self] in
                    self?.cancelActiveWork()
                }
            )
        case .ocr:
            presentationID = nil
            ocrResultPanel.showLoading(
                near: point,
                onCancel: { [weak self] in
                    self?.cancelActiveWork()
                }
            )
        case .silentOCR:
            presentationID = nil
            break
        }

        let taskToken = UUID()
        let task = Task { [ocrService, ocrResultPanel, translationService, floatingPanel, toastPanel, imageOverlayTranslationWindowController] in
            defer {
                Task { @MainActor [weak self] in
                    self?.finishActiveProcessingTask(ifMatches: taskToken)
                }
            }
            do {
                let startedAt = Date()
                if let translationEngine = mode.coordinateTranslationEngine {
                    let originalImage = try Self.loadImage(from: imageURL)
                    let windowTitle = translationEngine == .configuredProvider
                        ? "API 高质量坐标翻译"
                        : "Apple 本地坐标翻译"
                    await MainActor.run {
                        guard self.activeProcessingToken == taskToken else {
                            return
                        }
                        toastPanel.hide()
                        imageOverlayTranslationWindowController.showProgress(
                            originalImage: originalImage,
                            message: "正在 OCR 版式识别...",
                            title: windowTitle,
                            translationEngine: translationEngine,
                            onCancel: { [weak self] in
                                self?.cancelActiveWork()
                            }
                        )
                    }
                    let snapshot = try await ocrService.recognizeOverlaySnapshot(
                        from: originalImage,
                        displayPointSize: captureDisplaySize,
                        mode: .accurate
                    )
                    let segmentation = snapshot.layoutSnapshot?.segmentation ??
                        OverlaySegmentationSnapshot(textLines: [], overlaySegments: [])
                    let segments = segmentation.overlaySegments
                        .filter { !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    print(
                        "screenshot overlay stage: layout ocr elapsed=\(Self.elapsedSeconds(since: startedAt))s, observations=\(snapshot.ocrObservationCount), lines=\(segmentation.textLines.count), segments=\(segments.count)"
                    )
                    try Task.checkCancellation()

                    guard !segments.isEmpty else {
                        throw ScreenshotCaptureError.noRecognizedText
                    }

                    await MainActor.run {
                        guard self.activeProcessingToken == taskToken else {
                            return
                        }
                        imageOverlayTranslationWindowController.show(
                            originalImage: originalImage,
                            ocrSnapshot: snapshot,
                            segmentation: OverlaySegmentationSnapshot(
                                textLines: segmentation.textLines,
                                overlaySegments: segments
                            ),
                            stage: .accurate,
                            title: windowTitle,
                            translationEngine: translationEngine,
                            autoStart: true
                        )
                    }
                    return
                }

                let result = try await ocrService.recognizeText(from: imageURL, mode: .accurate)
                print("screenshot stage: ocr elapsed=\(Self.elapsedSeconds(since: startedAt))s, chars=\(result.plainText.count)")
                try Task.checkCancellation()
                let plainText = result.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !plainText.isEmpty else {
                    throw ScreenshotCaptureError.noRecognizedText
                }

                await MainActor.run {
                    guard self.activeProcessingToken == taskToken else {
                        return
                    }
                    switch mode {
                    case .clipboard:
                        break
                    case .translate:
                        if let presentationID {
                            floatingPanel.updateLoading(
                                sourceText: plainText,
                                near: point,
                                presentationID: presentationID
                            )
                        }
                    case .translateOverlay:
                        break
                    case .translateOverlayAPI, .translateOverlayLocal:
                        break
                    case .ocr:
                        ocrResultPanel.showResult(result, imageURL: imageURL, near: point)
                    case .silentOCR:
                        copyToPasteboard(plainText)
                        toastPanel.show("已复制 OCR 文本", near: point)
                    }
                }

                switch mode {
                case .clipboard:
                    break
                case .translate:
                    let item = try await translationService.translate(
                        text: plainText,
                        scenario: .screenshot,
                        mode: .ocrTranslate
                    )
                    print("screenshot stage: translation elapsed=\(Self.elapsedSeconds(since: startedAt))s")
                    try Task.checkCancellation()
                    await MainActor.run {
                        guard self.activeProcessingToken == taskToken else {
                            return
                        }
                        if let presentationID {
                            floatingPanel.showResult(
                                item: item,
                                near: point,
                                presentationID: presentationID
                            )
                        }
                    }
                case .translateOverlay:
                    break
                case .translateOverlayAPI, .translateOverlayLocal:
                    break
                case .ocr:
                    break
                case .silentOCR:
                    break
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.activeProcessingToken == taskToken else {
                        return
                    }
                    switch mode {
                    case .clipboard:
                        break
                    case .translate:
                        floatingPanel.hide()
                    case .translateOverlay:
                        imageOverlayTranslationWindowController.showCancelled()
                    case .translateOverlayAPI, .translateOverlayLocal:
                        toastPanel.hide()
                        imageOverlayTranslationWindowController.showCancelled()
                    case .ocr:
                        ocrResultPanel.hide()
                    case .silentOCR:
                        toastPanel.hide()
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.activeProcessingToken == taskToken else {
                        return
                    }
                    let message = error.localizedDescription
                    switch mode {
                    case .clipboard:
                        toastPanel.show(message, near: point)
                    case .translate:
                        if let presentationID {
                            floatingPanel.showError(message, near: point, presentationID: presentationID)
                        }
                    case .translateOverlay:
                        toastPanel.hide()
                        imageOverlayTranslationWindowController.showError(message)
                    case .translateOverlayAPI, .translateOverlayLocal:
                        toastPanel.hide()
                        imageOverlayTranslationWindowController.showError(message)
                    case .ocr:
                        ocrResultPanel.showError(message, near: point)
                    case .silentOCR:
                        toastPanel.show(message, near: point)
                    }
                }
            }
        }
        beginActiveProcessingTask(
            task,
            token: taskToken,
            mode: mode,
            anchorPoint: point
        )
    }

    @discardableResult
    private func cancelActiveProcessing(showFeedback: Bool) -> Bool {
        let hadActiveTask = activeProcessingTask != nil
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        activeProcessingToken = nil

        if let mode = activeProcessingMode {
            switch mode {
            case .clipboard:
                break
            case .translate:
                floatingPanel.hide()
            case .translateOverlay:
                imageOverlayTranslationWindowController.cancelCurrentWork()
            case .translateOverlayAPI, .translateOverlayLocal:
                toastPanel.hide()
                imageOverlayTranslationWindowController.showCancelled()
            case .ocr:
                ocrResultPanel.hide()
            case .silentOCR:
                toastPanel.hide()
            }
        }

        let anchorPoint = activeProcessingAnchorPoint
        activeProcessingMode = nil
        activeProcessingAnchorPoint = nil

        if showFeedback, hadActiveTask {
            toastPanel.show("已停止当前截图任务", near: anchorPoint)
        }

        return hadActiveTask
    }

    private func beginActiveProcessingTask(
        _ task: Task<Void, Never>,
        token: UUID,
        mode: ScreenshotCaptureMode,
        anchorPoint: NSPoint
    ) {
        activeProcessingTask = task
        activeProcessingToken = token
        activeProcessingMode = mode
        activeProcessingAnchorPoint = anchorPoint
    }

    private func finishActiveProcessingTask(ifMatches token: UUID) {
        guard activeProcessingToken == token else {
            return
        }

        activeProcessingTask = nil
        activeProcessingToken = nil
        activeProcessingMode = nil
        activeProcessingAnchorPoint = nil
    }

    private func captureScreenshot(
        selectionRect: CGRect,
        belowWindowID: CGWindowID
    ) throws -> CGImage {
        let displayRect = convertToDisplayRect(selectionRect)
        guard let image = CGWindowListCreateImage(
            displayRect,
            .optionOnScreenBelowWindow,
            belowWindowID,
            [.bestResolution]
        ) else {
            throw ScreenshotCaptureError.captureFailed
        }
        return image
    }

    private func saveScreenshot(
        image: CGImage,
        mode: ScreenshotCaptureMode
    ) throws -> URL {
        let directory: URL
        if mode.usesOverlayWindow {
            ScreenshotArtifactRetention.pruneExpiredOverlayArtifacts()
            directory = ScreenshotArtifactRetention.overlayScreenshotDirectory()
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tts-screenshots", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let fileURL = directory.appendingPathComponent("screenshot-\(timestamp).png")

        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotCaptureError.writeFailed
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotCaptureError.writeFailed
        }

        return fileURL
    }

    private func presentAnnotationEditor(
        image: CGImage,
        selectionRect: CGRect
    ) {
        let window = ScreenshotAnnotationWindow(
            image: image,
            selectionRect: selectionRect
        )
        let anchorPoint = NSPoint(x: selectionRect.maxX, y: selectionRect.maxY)
        window.onCopiedImage = { [weak self] image, logicalSize in
            guard let self else {
                return
            }
            guard Self.copyImageToPasteboard(image, logicalSize: logicalSize) else {
                self.clipboardToastPanel.show("复制截图失败，请重试", near: anchorPoint)
                return
            }
            self.closeAnnotationEditor()
            self.clipboardToastPanel.show("截图已复制", near: anchorPoint)
        }
        window.onCopyFailed = { [weak self] in
            self?.clipboardToastPanel.show("生成标注截图失败，请重试", near: anchorPoint)
        }
        window.onCancelled = { [weak self] in
            self?.closeAnnotationEditor()
            self?.clipboardToastPanel.show("已取消截图", near: anchorPoint)
        }
        annotationWindow = window
        isCapturing = true
        window.orderFrontRegardless()
    }

    private func closeAnnotationEditor() {
        annotationWindow?.dismissEditor()
        annotationWindow = nil
        isCapturing = false
    }

    static func pngData(
        for image: CGImage,
        logicalSize: CGSize
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let pointWidth = logicalSize.width.isFinite && logicalSize.width > 0
            ? logicalSize.width
            : CGFloat(image.width)
        let pointHeight = logicalSize.height.isFinite && logicalSize.height > 0
            ? logicalSize.height
            : CGFloat(image.height)
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * CGFloat(image.width) / pointWidth,
            kCGImagePropertyDPIHeight: 72 * CGFloat(image.height) / pointHeight
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private static func copyImageToPasteboard(
        _ image: CGImage,
        logicalSize: CGSize
    ) -> Bool {
        guard let data = pngData(for: image, logicalSize: logicalSize) else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }

    private static func loadImage(from imageURL: URL) throws -> NSImage {
        guard let image = NSImage(contentsOf: imageURL) else {
            throw ScreenshotCaptureError.captureFailed
        }
        return image
    }

    private static func elapsedSeconds(since startDate: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(startDate))
    }

    private func convertToDisplayRect(_ rect: CGRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else {
            return rect
        }

        let screenFrame = primaryScreen.frame
        return CGRect(
            x: rect.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

private enum ScreenshotCaptureError: LocalizedError {
    case captureFailed
    case writeFailed
    case noRecognizedText
    case overlayTranslationFailed

    var errorDescription: String? {
        switch self {
        case .captureFailed:
            "无法截取所选区域。"
        case .writeFailed:
            "无法写入截图文件。"
        case .noRecognizedText:
            "没有识别到文字，请重新选择包含文字的区域。"
        case .overlayTranslationFailed:
            "截图翻译覆盖失败，请检查翻译服务配置或网络连接。"
        }
    }
}

@MainActor
private func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
