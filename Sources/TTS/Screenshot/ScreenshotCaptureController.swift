import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotCaptureMode {
    case translate
    case translateOverlay
    case ocr
    case silentOCR
}

@MainActor
final class ScreenshotCaptureController {
    private let permissionManager: PermissionManager
    private let ocrService: OCRService
    private let ocrTextBlockGrouper: OCRTextBlockGrouper
    private let ocrResultPanel: OCRResultPanel
    private let translationService: TranslationService
    private let historyStore: HistoryStore
    private let floatingPanel: FloatingTranslatePanel
    private let toastPanel: ToastPanel
    private let translatedImagePreviewWindowController: TranslatedImagePreviewWindowController
    private var overlayWindows: [ScreenshotOverlayWindow] = []
    private var isCapturing = false
    private var didHideSystemCursor = false
    private var activeMode: ScreenshotCaptureMode = .translate

    init(
        permissionManager: PermissionManager,
        ocrService: OCRService,
        ocrTextBlockGrouper: OCRTextBlockGrouper,
        ocrResultPanel: OCRResultPanel,
        translationService: TranslationService,
        historyStore: HistoryStore,
        floatingPanel: FloatingTranslatePanel,
        toastPanel: ToastPanel,
        translatedImagePreviewWindowController: TranslatedImagePreviewWindowController
    ) {
        self.permissionManager = permissionManager
        self.ocrService = ocrService
        self.ocrTextBlockGrouper = ocrTextBlockGrouper
        self.ocrResultPanel = ocrResultPanel
        self.translationService = translationService
        self.historyStore = historyStore
        self.floatingPanel = floatingPanel
        self.toastPanel = toastPanel
        self.translatedImagePreviewWindowController = translatedImagePreviewWindowController
    }

    func startCapture(mode: ScreenshotCaptureMode) {
        guard !isCapturing else {
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

    func openImageFileOCR() {
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
        ocrResultPanel.showLoading(near: anchorPoint)

        Task { [ocrService, ocrResultPanel, historyStore] in
            do {
                let result = try await ocrService.recognizeText(from: imageURL, mode: .accurate)
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
            } catch {
                await MainActor.run {
                    ocrResultPanel.showError(error.localizedDescription, near: anchorPoint)
                }
            }
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
            let fileURL = try saveScreenshot(selectionRect: selectionRect)
            print("screenshot saved: \(fileURL.path)")
            handleScreenshot(imageURL: fileURL, near: NSPoint(x: selectionRect.maxX, y: selectionRect.maxY), mode: activeMode)
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

    private func handleScreenshot(imageURL: URL, near point: NSPoint, mode: ScreenshotCaptureMode) {
        let presentationID: UUID?
        switch mode {
        case .translate:
            presentationID = floatingPanel.showLoading(sourceText: "正在识别截图文字...", near: point)
        case .translateOverlay:
            presentationID = nil
            toastPanel.showLoading("正在生成截图翻译覆盖，可能需要一点时间...", near: point)
        case .ocr:
            presentationID = nil
            ocrResultPanel.showLoading(near: point)
        case .silentOCR:
            presentationID = nil
            break
        }

        Task { [ocrService, ocrTextBlockGrouper, ocrResultPanel, translationService, historyStore, floatingPanel, toastPanel, translatedImagePreviewWindowController] in
            do {
                if mode == .translateOverlay {
                    let originalImage = try Self.loadImage(from: imageURL)
                    let recognizedBlocks = try await ocrService.recognizeTextBlocks(from: originalImage, mode: .accurate)
                    let groupedBlocks = ocrTextBlockGrouper.group(recognizedBlocks)
                        .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

                    guard !groupedBlocks.isEmpty else {
                        throw ScreenshotCaptureError.noRecognizedText
                    }

                    let translationResults = try await translationService.translateImageOverlayBlocks(groupedBlocks)
                    let translatedBlocks = translationResults.map(\.translatedText)
                    let summary = translationResults.imageOverlaySummary
                    let translatedCount = summary.successCount + summary.fallbackCount

                    guard translatedCount > 0 else {
                        throw ScreenshotCaptureError.overlayTranslationFailed
                    }

                    try await MainActor.run {
                        toastPanel.hide()
                        try translatedImagePreviewWindowController.show(
                            originalImage: originalImage,
                            blocks: groupedBlocks,
                            translations: translatedBlocks,
                            summary: summary,
                            initialStyle: .solid
                        )
                        if summary.fallbackCount > 0 && summary.originalKeptCount > 0 {
                            toastPanel.show("部分文本块使用备用服务完成翻译。部分文本块翻译失败，已保留原文。", near: point)
                        } else if summary.fallbackCount > 0 {
                            toastPanel.show("部分文本块使用备用服务完成翻译。", near: point)
                        } else if summary.originalKeptCount > 0 {
                            toastPanel.show("部分文本块翻译失败，已保留原文。", near: point)
                        }
                    }
                    return
                }

                let result = try await ocrService.recognizeText(from: imageURL, mode: .accurate)
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
                        toastPanel.show(message, near: point)
                    case .ocr:
                        ocrResultPanel.showError(message, near: point)
                    case .silentOCR:
                        toastPanel.show(message, near: point)
                    }
                }
            }
        }
    }

    private func saveScreenshot(selectionRect: CGRect) throws -> URL {
        let displayRect = convertToDisplayRect(selectionRect)
        guard let image = CGWindowListCreateImage(
            displayRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            throw ScreenshotCaptureError.captureFailed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-screenshots", isDirectory: true)
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
