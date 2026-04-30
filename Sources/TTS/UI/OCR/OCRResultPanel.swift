import AppKit
import SwiftUI

@MainActor
final class OCRResultPanel {
    private let translationService: TranslationService
    private let providerFactory: TranslationProviderFactory
    private let floatingPanel: FloatingTranslatePanel
    private var panel: NSPanel?
    private var hostingController: NSHostingController<OCRResultView>?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private let panelSize = NSSize(width: 480, height: 360)
    private var currentCancelAction: (() -> Void)?

    init(
        translationService: TranslationService,
        providerFactory: TranslationProviderFactory,
        floatingPanel: FloatingTranslatePanel
    ) {
        self.translationService = translationService
        self.providerFactory = providerFactory
        self.floatingPanel = floatingPanel
    }

    func showLoading(near point: NSPoint, onCancel: (() -> Void)? = nil) {
        currentCancelAction = onCancel
        show(state: .loading, near: point)
    }

    func showResult(_ result: OCRResult, imageURL: URL, near point: NSPoint) {
        currentCancelAction = nil
        show(state: .result(result, imageURL: imageURL), near: point)
    }

    func showError(_ message: String, near point: NSPoint) {
        currentCancelAction = nil
        show(state: .error(message), near: point)
    }

    func hide() {
        currentCancelAction = nil
        panel?.orderOut(nil)
        removeDismissMonitors()
    }

    private func show(state: OCRResultPanelState, near point: NSPoint) {
        let view = OCRResultView(
            state: state,
            onCopy: copyToPasteboard(_:),
            onAICleanup: performAICleanup(text:),
            onTranslate: translateText(_:),
            supportsAICleanup: true,
            onCancelLoading: currentCancelAction,
            onClose: hide
        )

        if panel == nil {
            let newPanel = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.level = .floating
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            newPanel.isReleasedWhenClosed = false
            newPanel.isMovableByWindowBackground = true
            panel = newPanel
        }

        if let hostingController {
            hostingController.rootView = view
        } else {
            let controller = NSHostingController(rootView: view)
            hostingController = controller
            panel?.contentViewController = controller
        }

        panel?.setFrame(NSRect(origin: origin(for: point), size: panelSize), display: true)
        panel?.orderFrontRegardless()
        installDismissMonitorsIfNeeded()
    }

    private func installDismissMonitorsIfNeeded() {
        guard localMouseDownMonitor == nil, globalMouseDownMonitor == nil else {
            return
        }

        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor in
                self?.hideIfClickIsOutsidePanel()
            }
            return event
        }

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor in
                self?.hideIfClickIsOutsidePanel()
            }
        }
    }

    private func removeDismissMonitors() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }

        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
    }

    private func hideIfClickIsOutsidePanel() {
        guard let panel, panel.isVisible else {
            removeDismissMonitors()
            return
        }

        if !panel.frame.contains(NSEvent.mouseLocation) {
            hide()
        }
    }

    private func origin(for point: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return NSPoint(x: point.x + 12, y: point.y - panelSize.height - 12)
        }

        let preferred = NSPoint(x: point.x + 14, y: point.y - panelSize.height - 14)
        let x = min(max(preferred.x, visibleFrame.minX + 8), visibleFrame.maxX - panelSize.width - 8)
        let y = min(max(preferred.y, visibleFrame.minY + 8), visibleFrame.maxY - panelSize.height - 8)
        return NSPoint(x: x, y: y)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func performAICleanup(text: String) async throws -> String {
        let item = try await translationService.translate(
            text: text,
            translationMode: .ocrCleanup,
            scenario: .ocrCleanup,
            mode: .ocr
        )
        return item.translatedText
    }

    private func translateText(_ text: String) async throws {
        let anchor = actionAnchorPoint()
        let presentationID = floatingPanel.showLoading(sourceText: text, near: anchor)

        do {
            let item = try await translationService.translate(
                text: text,
                scenario: .screenshot,
                mode: .ocrTranslate
            )
            floatingPanel.showResult(item: item, near: anchor, presentationID: presentationID)
            hide()
        } catch {
            floatingPanel.showError(error.localizedDescription, near: anchor, presentationID: presentationID)
            throw error
        }
    }

    private func actionAnchorPoint() -> NSPoint {
        guard let panel else {
            return NSEvent.mouseLocation
        }

        return NSPoint(x: panel.frame.maxX - 18, y: panel.frame.maxY - 18)
    }
}

private enum OCRResultPanelState: Equatable {
    case loading
    case result(OCRResult, imageURL: URL)
    case error(String)
}

private struct OCRResultView: View {
    var state: OCRResultPanelState
    var onCopy: (String) -> Void
    var onAICleanup: (String) async throws -> String
    var onTranslate: (String) async throws -> Void
    var supportsAICleanup: Bool
    var onCancelLoading: (() -> Void)?
    var onClose: () -> Void
    @State private var displayedTextMode: OCRDisplayTextMode = .processed
    @State private var aiCleanedText: String?
    @State private var isAICleaning = false
    @State private var isTranslating = false
    @State private var actionMessage: String?
    @State private var actionIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            switch state {
            case .loading:
                loadingView
            case .result(let result, let imageURL):
                resultView(result, imageURL: imageURL)
            case .error(let message):
                errorView(message)
            }
        }
        .padding(16)
        .frame(width: 480, height: 360, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onChange(of: resultIdentity) { _ in
            displayedTextMode = .processed
            aiCleanedText = nil
            isAICleaning = false
            isTranslating = false
            actionMessage = nil
            actionIsError = false
        }
    }

    private var header: some View {
        HStack {
            Text("OCR 识别")
                .font(.headline)
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    private var loadingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在识别截图文字...")
                .foregroundStyle(.secondary)

            if let onCancelLoading {
                Button {
                    onCancelLoading()
                } label: {
                    Label("停止任务", systemImage: "stop.fill")
                }
                .controlSize(.small)
            }
        }
    }

    private func resultView(_ result: OCRResult, imageURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("置信度 \(Int(result.confidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(result.textBlocks.count) 个文本块")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(modeTitle(result.processingMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Picker("", selection: $displayedTextMode) {
                    Text("处理后文本").tag(OCRDisplayTextMode.processed)
                    if aiCleanedText != nil {
                        Text("AI 修复").tag(OCRDisplayTextMode.aiCleaned)
                    }
                    Text("原始 OCR").tag(OCRDisplayTextMode.raw)
                }
                .pickerStyle(.segmented)
                .frame(width: aiCleanedText == nil ? 220 : 300)

                Spacer()

                Text(displayModeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(displayedText(for: result).isEmpty ? "未识别到文字" : displayedText(for: result))
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button {
                    onCopy(preferredCopyText(for: result))
                } label: {
                    Label(copyButtonTitle, systemImage: "doc.on.doc")
                }
                .disabled(preferredCopyText(for: result).isEmpty)

                Button {
                    Task {
                        await triggerAICleanup(using: result)
                    }
                } label: {
                    if isAICleaning {
                        Label("AI 修复中...", systemImage: "sparkles")
                    } else {
                        Label("AI 修复", systemImage: "sparkles")
                    }
                }
                .disabled(isAICleaning || isTranslating || preferredCleanupInput(for: result).isEmpty)

                Button {
                    Task {
                        await triggerTranslate(using: result)
                    }
                } label: {
                    if isTranslating {
                        Label("翻译中...", systemImage: "arrow.right.circle")
                    } else {
                        Label("继续翻译", systemImage: "arrow.right.circle")
                    }
                }
                .disabled(isAICleaning || isTranslating || preferredTranslationInput(for: result).isEmpty)

                Text(imageURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()
            }
            .controlSize(.small)

            if let actionMessage, !actionMessage.isEmpty {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(actionIsError ? .red : .secondary)
                    .lineLimit(2)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }

    private var resultIdentity: String {
        switch state {
        case .loading:
            "loading"
        case .error(let message):
            "error-\(message)"
        case .result(let result, _):
            result.rawText + result.processedText
        }
    }

    private func displayedText(for result: OCRResult) -> String {
        switch displayedTextMode {
        case .processed:
            result.processedText
        case .aiCleaned:
            aiCleanedText ?? result.processedText
        case .raw:
            result.rawText
        }
    }

    private var displayModeTitle: String {
        switch displayedTextMode {
        case .processed:
            "当前显示：处理后文本"
        case .aiCleaned:
            "当前显示：AI 修复文本"
        case .raw:
            "当前显示：原始 OCR 文本"
        }
    }

    private var copyButtonTitle: String {
        aiCleanedText == nil ? "复制处理后文本" : "复制 AI 修复文本"
    }

    private func preferredCopyText(for result: OCRResult) -> String {
        aiCleanedText ?? result.processedText
    }

    private func preferredCleanupInput(for result: OCRResult) -> String {
        result.processedText
    }

    private func preferredTranslationInput(for result: OCRResult) -> String {
        aiCleanedText ?? result.processedText
    }

    private func triggerAICleanup(using result: OCRResult) async {
        actionMessage = nil

        guard supportsAICleanup else {
            actionIsError = true
            actionMessage = "当前默认服务不支持 AI 修复，请切换到 AI 大模型服务。"
            return
        }

        isAICleaning = true
        defer { isAICleaning = false }

        do {
            let cleaned = try await onAICleanup(preferredCleanupInput(for: result))
            aiCleanedText = cleaned
            displayedTextMode = .aiCleaned
            actionIsError = false
            actionMessage = "AI 修复完成。"
        } catch {
            actionIsError = true
            actionMessage = error.localizedDescription
        }
    }

    private func triggerTranslate(using result: OCRResult) async {
        actionMessage = nil
        isTranslating = true
        defer { isTranslating = false }

        do {
            try await onTranslate(preferredTranslationInput(for: result))
            actionIsError = false
        } catch {
            actionIsError = true
            actionMessage = error.localizedDescription
        }
    }

    private func modeTitle(_ mode: OCRTextProcessingMode) -> String {
        switch mode {
        case .plainText:
            "纯文本整理"
        case .article:
            "文章整理"
        case .code:
            "代码整理"
        case .markdown:
            "Markdown 整理"
        case .auto:
            "自动整理"
        }
    }
}

private enum OCRDisplayTextMode {
    case processed
    case aiCleaned
    case raw
}
