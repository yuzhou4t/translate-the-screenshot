import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotCaptureMode {
    case translate
    case translateOverlay
    case translateOverlayLocal
    case ocr
    case silentOCR
}

@MainActor
final class ScreenshotCaptureController {
    private let permissionManager: PermissionManager
    private let ocrService: OCRService
    private let ocrResultPanel: OCRResultPanel
    private let translationService: TranslationService
    private let historyStore: HistoryStore
    private let floatingPanel: FloatingTranslatePanel
    private let toastPanel: ToastPanel
    private let imageOverlayTranslationWindowController: ImageOverlayTranslationWindowController
    private let providerRegistry: ProviderRegistry
    private let policyStore: VolcengineImageTranslationPolicyStore
    private let settingsWindowController: SettingsWindowController
    private var overlayWindows: [ScreenshotOverlayWindow] = []
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
        historyStore: HistoryStore,
        floatingPanel: FloatingTranslatePanel,
        toastPanel: ToastPanel,
        imageOverlayTranslationWindowController: ImageOverlayTranslationWindowController,
        providerRegistry: ProviderRegistry,
        policyStore: VolcengineImageTranslationPolicyStore,
        settingsWindowController: SettingsWindowController
    ) {
        self.permissionManager = permissionManager
        self.ocrService = ocrService
        self.ocrResultPanel = ocrResultPanel
        self.translationService = translationService
        self.historyStore = historyStore
        self.floatingPanel = floatingPanel
        self.toastPanel = toastPanel
        self.imageOverlayTranslationWindowController = imageOverlayTranslationWindowController
        self.providerRegistry = providerRegistry
        self.policyStore = policyStore
        self.settingsWindowController = settingsWindowController
    }

    func startCapture(mode: ScreenshotCaptureMode) {
        guard !isCapturing else {
            return
        }

        cancelActiveProcessing(showFeedback: false)
        if mode == .translateOverlay || mode == .translateOverlayLocal {
            imageOverlayTranslationWindowController.cancelCurrentWork()
        }

        if mode == .translateOverlay, !prepareVolcengineImageTranslation() {
            return
        }

        guard permissionManager.isScreenRecordingTrusted else {
            permissionManager.requestScreenRecordingIfNeeded()
            permissionManager.openScreenRecordingSettings()
            toastPanel.show("请允许 TTS 屏幕录制，授权后重启 TTS")
            print("screenshot cancelled: screen recording permission required")
            return
        }

        isCapturing = true
        activeMode = mode
        hideSystemCursor()
        overlayWindows = NSScreen.screens.map { screen in
            let window = ScreenshotOverlayWindow(screen: screen)
            window.onFinished = { [weak self] selectionRect in
                self?.finishCapture(selectionRect: selectionRect)
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
            toastPanel.show("火山图片翻译本月安全计数已达 \(usage.limit) 张上限；可从菜单使用本地坐标备用")
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
        Option + W 框选的完整截图会上传到火山引擎进行 OCR、翻译和整图回填。

        你只需同意一次；之后快捷键会直接上传。每次提交前会同步火山账号当月图片用量，并与本机保守计数取较大值；免费 100 张用完后直接阻止。失败或超时也计入本机限额。
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
        let task = Task { [ocrService, ocrResultPanel, historyStore] in
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

                let item = TranslationHistoryItem(
                    sourceText: plainText,
                    translatedText: plainText,
                    providerID: .localOCR,
                    sourceLanguage: nil,
                    targetLanguage: "",
                    createdAt: Date(),
                    mode: .ocr
                )
                try await historyStore.add(item)

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
        if isCapturing {
            cancelCapture()
            toastPanel.show("已取消截图选择", near: activeProcessingAnchorPoint)
            return
        }

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

    private func finishCapture(selectionRect: CGRect) {
        guard isCapturing else {
            return
        }

        closeOverlays()

        guard selectionRect.width >= 2, selectionRect.height >= 2 else {
            print("screenshot cancelled")
            return
        }

        do {
            let fileURL = try saveScreenshot(
                selectionRect: selectionRect,
                mode: activeMode
            )
            print("screenshot saved: \(fileURL.path)")
            handleScreenshot(
                imageURL: fileURL,
                near: NSPoint(x: selectionRect.maxX, y: selectionRect.maxY),
                mode: activeMode,
                captureDisplaySize: selectionRect.size
            )
        } catch {
            print("screenshot failed: \(error.localizedDescription)")
        }
    }

    private func cancelCapture() {
        guard isCapturing else {
            return
        }

        closeOverlays()
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
        case .translateOverlayLocal:
            presentationID = nil
            toastPanel.showLoading(
                "正在准备本地坐标翻译...",
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
        let task = Task { [ocrService, ocrResultPanel, translationService, historyStore, floatingPanel, toastPanel, imageOverlayTranslationWindowController] in
            defer {
                Task { @MainActor [weak self] in
                    self?.finishActiveProcessingTask(ifMatches: taskToken)
                }
            }
            do {
                let startedAt = Date()
                if mode == .translateOverlayLocal {
                    let originalImage = try Self.loadImage(from: imageURL)
                    await MainActor.run {
                        toastPanel.hide()
                        imageOverlayTranslationWindowController.showProgress(
                            originalImage: originalImage,
                            message: "正在 OCR 版式识别...",
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
                        imageOverlayTranslationWindowController.show(
                            originalImage: originalImage,
                            ocrSnapshot: snapshot,
                            segmentation: OverlaySegmentationSnapshot(
                                textLines: segmentation.textLines,
                                overlaySegments: segments
                            ),
                            stage: .accurate,
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
                    switch mode {
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
                    case .translateOverlayLocal:
                        break
                    case .ocr:
                        ocrResultPanel.showResult(result, imageURL: imageURL, near: point)
                    case .silentOCR:
                        copyToPasteboard(plainText)
                        toastPanel.show("已复制 OCR 文本", near: point)
                    }
                }

                switch mode {
                case .translate:
                    let item = try await translationService.translate(
                        text: plainText,
                        scenario: .screenshot,
                        mode: .ocrTranslate
                    )
                    print("screenshot stage: translation elapsed=\(Self.elapsedSeconds(since: startedAt))s")
                    try Task.checkCancellation()
                    await MainActor.run {
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
                case .translateOverlayLocal:
                    break
                case .ocr:
                    let item = TranslationHistoryItem(
                        sourceText: plainText,
                        translatedText: plainText,
                        providerID: .localOCR,
                        sourceLanguage: nil,
                        targetLanguage: "",
                        createdAt: Date(),
                        mode: .ocr
                    )
                    try await historyStore.add(item)
                case .silentOCR:
                    break
                }
            } catch is CancellationError {
                await MainActor.run {
                    switch mode {
                    case .translate:
                        floatingPanel.hide()
                    case .translateOverlay:
                        imageOverlayTranslationWindowController.showCancelled()
                    case .translateOverlayLocal:
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
                    let message = error.localizedDescription
                    switch mode {
                    case .translate:
                        if let presentationID {
                            floatingPanel.showError(message, near: point, presentationID: presentationID)
                        }
                    case .translateOverlay:
                        toastPanel.hide()
                        imageOverlayTranslationWindowController.showError(message)
                    case .translateOverlayLocal:
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
            case .translate:
                floatingPanel.hide()
            case .translateOverlay:
                imageOverlayTranslationWindowController.cancelCurrentWork()
            case .translateOverlayLocal:
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

    private func saveScreenshot(
        selectionRect: CGRect,
        mode: ScreenshotCaptureMode
    ) throws -> URL {
        let displayRect = convertToDisplayRect(selectionRect)
        guard let image = CGWindowListCreateImage(
            displayRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            throw ScreenshotCaptureError.captureFailed
        }

        let directory: URL
        if mode == .translateOverlay || mode == .translateOverlayLocal {
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
