import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotCaptureMode {
    case translate
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
    private var overlayWindows: [ScreenshotOverlayWindow] = []
    private var isCapturing = false
    private var didHideSystemCursor = false
    private var activeMode: ScreenshotCaptureMode = .translate

    init(
        permissionManager: PermissionManager,
        ocrService: OCRService,
        ocrResultPanel: OCRResultPanel,
        translationService: TranslationService,
        historyStore: HistoryStore,
        floatingPanel: FloatingTranslatePanel,
        toastPanel: ToastPanel
    ) {
        self.permissionManager = permissionManager
        self.ocrService = ocrService
        self.ocrResultPanel = ocrResultPanel
        self.translationService = translationService
        self.historyStore = historyStore
        self.floatingPanel = floatingPanel
        self.toastPanel = toastPanel
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
        switch mode {
        case .translate:
            floatingPanel.showLoading(sourceText: "正在识别截图文字...", near: point)
        case .ocr:
            ocrResultPanel.showLoading(near: point)
        case .silentOCR:
            break
        }

        Task { [ocrService, ocrResultPanel, translationService, historyStore, floatingPanel, toastPanel] in
            do {
                let result = try await ocrService.recognizeText(from: imageURL, mode: .accurate)
                let plainText = result.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !plainText.isEmpty else {
                    throw ScreenshotCaptureError.noRecognizedText
                }

                await MainActor.run {
                    switch mode {
                    case .translate:
                        floatingPanel.showLoading(sourceText: plainText, near: point)
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
                        mode: .ocrTranslate
                    )
                    await MainActor.run {
                        floatingPanel.showResult(item: item, near: point)
                    }
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
                        floatingPanel.showError(message, near: point)
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

    var errorDescription: String? {
        switch self {
        case .captureFailed:
            "无法截取所选区域。"
        case .writeFailed:
            "无法写入截图文件。"
        case .noRecognizedText:
            "没有识别到文字，请重新选择包含文字的区域。"
        }
    }
}

@MainActor
private func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
