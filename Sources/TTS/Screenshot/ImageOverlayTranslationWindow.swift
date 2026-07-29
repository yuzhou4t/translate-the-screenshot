import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ImageOverlayTranslationWindowController: NSObject, NSWindowDelegate {
    private let viewModel: ImageOverlayTranslationViewModel
    private var window: NSWindow?
    private var cancelProcessingAction: (() -> Void)?

    init(
        renderer: ScreenshotTranslationOverlayRenderer,
        translationService: TranslationService,
        debugWriter: OverlayPipelineDebugWriter,
        providerRegistry: ProviderRegistry,
        configurationStore: AppConfigurationStore,
        policyStore: VolcengineImageTranslationPolicyStore,
        openVolcengineSettings: @escaping () -> Void
    ) {
        viewModel = ImageOverlayTranslationViewModel(
            renderer: renderer,
            translationService: translationService,
            debugWriter: debugWriter,
            providerRegistry: providerRegistry,
            configurationStore: configurationStore,
            policyStore: policyStore,
            openVolcengineSettings: openVolcengineSettings
        )
        super.init()
    }

    func show(
        originalImage: NSImage,
        ocrSnapshot: OverlayOCRSnapshot,
        segmentation: OverlaySegmentationSnapshot,
        stage: ImageOverlayOCRStage,
        title: String = "截图覆盖翻译",
        autoStart: Bool = false
    ) {
        cancelProcessingAction = nil
        ensureWindow(title: title)

        viewModel.configure(
            originalImage: originalImage,
            ocrSnapshot: ocrSnapshot,
            segmentation: segmentation,
            stage: stage
        )

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if autoStart {
            viewModel.startTranslation()
        }
    }

    func showVolcengineTranslation(
        originalImage: NSImage,
        imageURL: URL,
        onUseLocalFallback: @escaping () -> Void
    ) {
        cancelProcessingAction = nil
        ensureWindow(title: "火山图片翻译 Beta")
        viewModel.configureVolcengineTranslation(
            originalImage: originalImage,
            imageURL: imageURL,
            onUseLocalFallback: onUseLocalFallback
        )
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func showProgress(
        originalImage: NSImage,
        message: String,
        title: String = "截图覆盖翻译",
        onCancel: (() -> Void)? = nil
    ) {
        cancelProcessingAction = onCancel
        ensureWindow(title: title)
        viewModel.configureProgress(originalImage: originalImage, message: message)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func showError(_ message: String) {
        cancelProcessingAction = nil
        viewModel.showProcessingError(message)
    }

    func showCancelled() {
        cancelProcessingAction = nil
        viewModel.showCancelled()
    }

    @discardableResult
    func cancelCurrentWork() -> Bool {
        let hadActiveWork = viewModel.isTranslating || cancelProcessingAction != nil
        cancelCurrentWorkIfNeeded()
        return hadActiveWork
    }

    private func ensureWindow(title: String) {
        if window == nil {
            let rootView = ImageOverlayTranslationView(
                viewModel: viewModel,
                onClose: { [weak self] in
                    self?.closeWindow()
                }
            )
            let controller = NSHostingController(rootView: rootView)
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.title = title
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.titlebarAppearsTransparent = true
            newWindow.toolbarStyle = .unifiedCompact
            newWindow.setContentSize(NSSize(width: 1120, height: 820))
            newWindow.minSize = NSSize(width: 860, height: 580)
            newWindow.center()
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            window = newWindow
        } else {
            window?.title = title
        }
    }

    private func closeWindow() {
        cancelCurrentWorkIfNeeded()
        viewModel.releaseImages()
        window?.performClose(nil)
    }

    private func cancelCurrentWorkIfNeeded() {
        let action = cancelProcessingAction
        cancelProcessingAction = nil
        action?()
        viewModel.cancelTranslation()
    }

    func windowWillClose(_ notification: Notification) {
        cancelCurrentWorkIfNeeded()
        viewModel.releaseImages()
    }
}

private enum ImageOverlayWorkflow {
    case local
    case volcengine
}

@MainActor
private final class ImageOverlayTranslationViewModel: ObservableObject {
    @Published var session: ImageOverlaySession?
    @Published var statusMessage = ""
    @Published var statusIsError = false
    @Published var isTranslating = false
    @Published var completedTranslationCount = 0
    @Published var totalTranslationCount = 0
    @Published var progressStage = "等待"
    @Published private var hasGeneratedResult = false
    @Published private var workflow: ImageOverlayWorkflow = .local
    @Published private var volcengineResultImage: NSImage?
    @Published private var volcengineTextBlocks: [VolcengineImageTextBlock] = []

    private let renderer: ScreenshotTranslationOverlayRenderer
    private let translationService: TranslationService
    private let debugWriter: OverlayPipelineDebugWriter
    private let providerRegistry: ProviderRegistry
    private let configurationStore: AppConfigurationStore
    private let policyStore: VolcengineImageTranslationPolicyStore
    private let openVolcengineSettingsAction: () -> Void
    private var translationTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var volcengineImageURL: URL?
    private var useLocalFallbackAction: (() -> Void)?
    #if canImport(Translation)
    private var appleTranslationCoordinatorStorage: AnyObject?
    #endif
    private var savedHistoryFingerprint: String?

    init(
        renderer: ScreenshotTranslationOverlayRenderer,
        translationService: TranslationService,
        debugWriter: OverlayPipelineDebugWriter,
        providerRegistry: ProviderRegistry,
        configurationStore: AppConfigurationStore,
        policyStore: VolcengineImageTranslationPolicyStore,
        openVolcengineSettings: @escaping () -> Void
    ) {
        self.renderer = renderer
        self.translationService = translationService
        self.debugWriter = debugWriter
        self.providerRegistry = providerRegistry
        self.configurationStore = configurationStore
        self.policyStore = policyStore
        openVolcengineSettingsAction = openVolcengineSettings
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            appleTranslationCoordinatorStorage = AppleOverlayTranslationCoordinator()
        }
        #endif
    }

    #if canImport(Translation)
    @available(macOS 15.0, *)
    var appleTranslationCoordinator: AppleOverlayTranslationCoordinator? {
        appleTranslationCoordinatorStorage as? AppleOverlayTranslationCoordinator
    }
    #endif

    var imagePixelSize: CGSize {
        let image = previewImage
        guard image.size != .zero,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .zero
        }
        return CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
    }

    var regions: [OverlayDisplayRegion] {
        guard workflow == .local else {
            return []
        }
        return session?.displayRegions ?? []
    }

    var previewImage: NSImage {
        volcengineResultImage ?? session?.originalImage ?? NSImage(size: .zero)
    }

    var selectedState: ImageOverlaySegmentState? {
        guard workflow == .local else {
            return nil
        }
        guard let session,
              let selectedID = session.selectedSegmentID else {
            return nil
        }
        return session.segmentStates.first { $0.id == selectedID }
    }

    var translationProgressText: String {
        guard totalTranslationCount > 0 else {
            return "未开始"
        }
        return "\(completedTranslationCount)/\(totalTranslationCount)"
    }

    var canStartTranslation: Bool {
        if workflow == .volcengine {
            return canRetryVolcengine
        }
        guard !isTranslating,
              let session else {
            return false
        }
        return session.segmentStates.contains { $0.canTranslate && $0.translationResult == nil }
    }

    var canRetrySelected: Bool {
        guard workflow == .local else {
            return false
        }
        guard !isTranslating, let selectedState else {
            return false
        }
        return selectedState.segment.shouldTranslate && !selectedState.isExcluded
    }

    var shouldShowResultImage: Bool {
        hasGeneratedResult && !isTranslating
    }

    var shouldShowPreview: Bool {
        session != nil && imagePixelSize.width > 0 && imagePixelSize.height > 0
    }

    var isProcessing: Bool {
        progressStage == "OCR" || isTranslating
    }

    var canExportImage: Bool {
        shouldShowResultImage
    }

    var canCopyOCRText: Bool {
        if workflow == .volcengine {
            return volcengineTextBlocks.contains {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        guard let text = session?.recognizedText else {
            return false
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canOpenDebugDirectory: Bool {
        guard workflow == .local else {
            return false
        }
        guard let session else {
            return false
        }
        return !session.textLines.isEmpty || !session.segmentStates.isEmpty
    }

    var isVolcengineWorkflow: Bool {
        workflow == .volcengine
    }

    var workflowBadgeText: String {
        isVolcengineWorkflow ? "火山整图 Beta · 云端" : "本地坐标 · 备用"
    }

    var monthlyUsageText: String {
        let snapshot = policyStore.snapshot
        return "本月安全计数 \(snapshot.submittedCount)/\(snapshot.limit)"
    }

    var canRetryVolcengine: Bool {
        workflow == .volcengine &&
            !isTranslating &&
            volcengineResultImage == nil &&
            policyStore.snapshot.remainingCount > 0 &&
            volcengineImageURL != nil
    }

    var canUseLocalFallback: Bool {
        workflow == .volcengine && !isTranslating && useLocalFallbackAction != nil
    }

    var volcengineTextBlockCount: Int {
        volcengineTextBlocks.count
    }

    func configure(
        originalImage: NSImage,
        ocrSnapshot: OverlayOCRSnapshot,
        segmentation: OverlaySegmentationSnapshot,
        stage: ImageOverlayOCRStage
    ) {
        translationTask?.cancel()
        translationTask = nil
        isTranslating = false
        completedTranslationCount = 0
        totalTranslationCount = 0
        hasGeneratedResult = false
        savedHistoryFingerprint = nil
        workflow = .local
        clearVolcengineState(keepOriginalSession: true)
        session = ImageOverlaySession.make(
            originalImage: originalImage,
            ocrSnapshot: ocrSnapshot,
            segmentation: segmentation,
            stage: stage
        )
        progressStage = "OCR 完成"
        status("OCR 完成，正在准备翻译。", isError: false)
    }

    func configureProgress(originalImage: NSImage, message: String) {
        translationTask?.cancel()
        translationTask = nil
        isTranslating = false
        completedTranslationCount = 0
        totalTranslationCount = 0
        hasGeneratedResult = false
        savedHistoryFingerprint = nil
        workflow = .local
        clearVolcengineState(keepOriginalSession: true)
        session = ImageOverlaySession(
            originalImage: originalImage,
            ocrSnapshot: OverlayOCRSnapshot(
                ocrObservationCount: 0,
                ocrBlocks: [],
                textAtoms: [],
                layoutSnapshot: nil,
                scaleFactor: 1,
                ocrScaleFactor: 1,
                originalImageSize: imagePixelSize(for: originalImage),
                ocrImageSize: imagePixelSize(for: originalImage),
                displayPointSize: originalImage.size,
                backingScaleFactor: 1,
                effectiveScaleFactor: 1,
                cropOrigin: .zero,
                coordinateSpace: .pixel,
                ocrInputImage: originalImage,
                boxDebugInfo: []
            ),
            ocrStage: .accurate,
            textLines: [],
            segmentStates: [],
            zoomScale: 1,
            showOCRBoxes: false,
            selectedSegmentID: nil,
            debugDirectory: nil
        )
        progressStage = "OCR"
        status(message, isError: false)
    }

    func configureVolcengineTranslation(
        originalImage: NSImage,
        imageURL: URL,
        onUseLocalFallback: @escaping () -> Void
    ) {
        configureProgress(
            originalImage: originalImage,
            message: "正在上传并生成整图译文..."
        )
        workflow = .volcengine
        volcengineImageURL = imageURL
        useLocalFallbackAction = onUseLocalFallback
        progressStage = "火山云端"
        startVolcengineTranslation()
    }

    func showProcessingError(_ message: String) {
        isTranslating = false
        translationTask = nil
        progressStage = "失败"
        status(message, isError: true)
    }

    func showCancelled() {
        isTranslating = false
        translationTask = nil
        activeRequestID = nil
        progressStage = "已取消"
        status("已取消当前处理。", isError: false)
    }

    func releaseImages() {
        translationTask?.cancel()
        translationTask = nil
        activeRequestID = nil
        session = nil
        clearVolcengineState(keepOriginalSession: false)
        progressStage = "等待"
    }

    func startTranslation() {
        if workflow == .volcengine {
            startVolcengineTranslation()
            return
        }
        guard let session else {
            return
        }

        let segments = session.segmentStates
            .filter { $0.canTranslate && $0.translationResult == nil }
            .map(\.segment)
        guard !segments.isEmpty else {
            hasGeneratedResult = true
            progressStage = "已生成"
            status("没有需要翻译的 OCR 区域。", isError: false)
            return
        }

        translate(segments: segments, resetProgress: true)
    }

    func retrySelected() {
        guard let selectedState, selectedState.segment.shouldTranslate else {
            return
        }
        translate(segments: [selectedState.segment], resetProgress: false)
    }

    func cancelTranslation() {
        translationTask?.cancel()
        translationTask = nil
        activeRequestID = nil
        #if canImport(Translation)
        if workflow == .local, #available(macOS 15.0, *) {
            appleTranslationCoordinator?.cancel()
        }
        #endif
        isTranslating = false
        if workflow == .volcengine {
            progressStage = "已取消"
            status("已停止火山图片翻译；没有自动切换到本地。", isError: false)
            return
        }
        markTranslatingSegmentsAsRecognized()
        status("已取消翻译。", isError: false)
    }

    func useLocalFallback() {
        guard canUseLocalFallback else {
            return
        }
        let action = useLocalFallbackAction
        translationTask?.cancel()
        translationTask = nil
        activeRequestID = nil
        action?()
    }

    func openVolcengineSettings() {
        openVolcengineSettingsAction()
    }

    func selectSegment(_ id: String?) {
        session?.selectedSegmentID = id
    }

    func toggleOCRBoxes() {
        session?.showOCRBoxes.toggle()
    }

    func toggleSelectedExclusion() {
        guard var session,
              let selectedID = session.selectedSegmentID,
              let index = session.segmentStates.firstIndex(where: { $0.id == selectedID }) else {
            return
        }

        session.segmentStates[index].isExcluded.toggle()
        if session.segmentStates[index].isExcluded {
            session.segmentStates[index].phase = .excluded
        } else if let result = session.segmentStates[index].translationResult {
            session.segmentStates[index].phase = result.status.livePhase
        } else {
            session.segmentStates[index].phase = session.segmentStates[index].segment.shouldTranslate ? .recognized : .originalKept
        }
        self.session = session
    }

    func zoomIn() {
        session?.zoomScale = min((session?.zoomScale ?? 1) + 0.2, 4)
    }

    func zoomOut() {
        session?.zoomScale = max((session?.zoomScale ?? 1) - 0.2, 0.5)
    }

    func resetZoom() {
        session?.zoomScale = 1
    }

    func copyOCRText() {
        let text: String
        if workflow == .volcengine {
            text = volcengineTextBlocks
                .map(\.text)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        } else {
            text = session?.recognizedText ?? ""
        }

        guard
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status("没有可复制的 OCR 文本。", isError: true)
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status("已复制 OCR 文本。", isError: false)
    }

    func copyImage() {
        guard canExportImage else {
            status("图片仍在生成中，请稍后。", isError: true)
            return
        }

        let image = exportImage()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([image]) {
            status("已复制翻译图片。", isError: false)
        } else {
            status("复制图片失败。", isError: true)
        }
    }

    func saveImage() {
        guard canExportImage else {
            status("图片仍在生成中，请稍后。", isError: true)
            return
        }

        let image = exportImage()
        guard let pngData = pngData(for: image) else {
            status("保存失败，无法导出 PNG。", isError: true)
            return
        }

        let panel = NSSavePanel()
        panel.title = "保存翻译图片"
        let prefix = workflow == .volcengine ? "tts-volcengine" : "tts-overlay"
        panel.nameFieldStringValue = "\(prefix)-\(Int(Date().timeIntervalSince1970)).png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try pngData.write(to: url)
            status("已保存 PNG。", isError: false)
        } catch {
            status("保存失败：\(error.localizedDescription)", isError: true)
        }
    }

    func openDebugDirectory() {
        guard var session else {
            return
        }

        if let directory = debugWriter.writeSessionArtifacts(
            originalImage: session.originalImage,
            ocrSnapshot: session.ocrSnapshot,
            segmentation: OverlaySegmentationSnapshot(
                textLines: session.textLines,
                overlaySegments: session.segments
            ),
            displayRegions: session.displayRegions,
            translationResults: session.segmentStates.compactMap(\.translationResult),
            renderer: renderer,
            force: true
        ) {
            session.debugDirectory = directory
            self.session = session
            NSWorkspace.shared.open(directory)
            status("已打开 debug 目录。", isError: false)
        } else {
            status("生成 debug 目录失败。", isError: true)
        }
    }

    private func startVolcengineTranslation() {
        guard workflow == .volcengine,
              let imageURL = volcengineImageURL else {
            return
        }

        translationTask?.cancel()
        let requestID = UUID()
        activeRequestID = requestID
        volcengineResultImage = nil
        volcengineTextBlocks = []
        hasGeneratedResult = false
        isTranslating = true
        completedTranslationCount = 0
        totalTranslationCount = 0
        progressStage = "火山云端"
        status("正在准备截图并核对火山账号当月免费额度…", isError: false)

        translationTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let provider = try providerRegistry.makeVolcengineImageTranslationProvider()
                let billingRange = Self.currentVolcengineBillingDateRange()
                let preparationTask = Task.detached(priority: .userInitiated) {
                    let originalData = try Data(contentsOf: imageURL)
                    return try VolcengineImagePayloadEncoder.encode(
                        originalData: originalData
                    )
                }
                let usageTask = Task.detached(priority: .userInitiated) {
                    do {
                        return try await provider.getImageUsage(
                            from: billingRange.from,
                            to: billingRange.to
                        )
                    } catch {
                        throw TranslationProviderError.providerMessage(
                            "无法确认火山账号当月图片用量，为避免超出免费额度已停止提交：\(error.localizedDescription)"
                        )
                    }
                }
                let preparedImage: VolcengineImagePayload
                let accountUsage: Int
                do {
                    (preparedImage, accountUsage) = try await withTaskCancellationHandler {
                        let preparedImage = try await preparationTask.value
                        let accountUsage = try await usageTask.value
                        return (preparedImage, accountUsage)
                    } onCancel: {
                        preparationTask.cancel()
                        usageTask.cancel()
                    }
                } catch {
                    preparationTask.cancel()
                    usageTask.cancel()
                    throw error
                }
                try Task.checkCancellation()

                let usage = try policyStore.reserveSubmission(
                    accountSubmittedCount: accountUsage
                )
                status(
                    "已提交火山图片翻译，本月安全计数 \(usage.submittedCount)/\(usage.limit)…",
                    isError: false
                )

                let startedAt = Date()
                let targetLanguage = configurationStore.targetLanguage
                let imageRequestTask = Task.detached(priority: .userInitiated) {
                    try await provider.translatePreparedImage(
                        preparedImage,
                        targetLanguage: targetLanguage
                    )
                }
                let result = try await withTaskCancellationHandler {
                    try await imageRequestTask.value
                } onCancel: {
                    imageRequestTask.cancel()
                }
                try Task.checkCancellation()
                guard activeRequestID == requestID else {
                    return
                }
                guard let translatedImage = NSImage(data: result.imageData) else {
                    throw TranslationProviderError.invalidResponse
                }

                volcengineResultImage = translatedImage
                volcengineTextBlocks = result.textBlocks
                completedTranslationCount = result.textBlocks.count
                totalTranslationCount = result.textBlocks.count
                hasGeneratedResult = true
                isTranslating = false
                translationTask = nil
                activeRequestID = nil
                progressStage = "已生成"

                let elapsed = String(
                    format: "%.2f",
                    Date().timeIntervalSince(startedAt)
                )
                status(
                    "火山整图翻译完成（\(elapsed) 秒），本月安全计数 \(policyStore.snapshot.submittedCount)/\(policyStore.snapshot.limit)。",
                    isError: false
                )
                print(
                    "volcengine image translation completed: elapsed=\(elapsed)s, blocks=\(result.textBlocks.count), request=\(result.responseMetadata?.requestID ?? "-")"
                )
                await saveVolcengineHistoryIfPossible(result.textBlocks)
            } catch is CancellationError {
                guard activeRequestID == requestID else {
                    return
                }
                isTranslating = false
                translationTask = nil
                activeRequestID = nil
                progressStage = "已取消"
                status("已停止火山图片翻译；没有自动切换到本地。", isError: false)
            } catch {
                guard activeRequestID == requestID else {
                    return
                }
                isTranslating = false
                translationTask = nil
                activeRequestID = nil
                progressStage = "失败"
                status(
                    "\(error.localizedDescription) 未自动切换本地，可手动选择“本地坐标备用”。",
                    isError: true
                )
            }
        }
    }

    private func saveVolcengineHistoryIfPossible(
        _ textBlocks: [VolcengineImageTextBlock]
    ) async {
        let pairs = textBlocks.compactMap { block -> (String, String)? in
            let source = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = block.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !translation.isEmpty else {
                return nil
            }
            return (source, translation)
        }
        guard !pairs.isEmpty else {
            return
        }

        do {
            _ = try await translationService.recordImageOverlayHistory(
                sourceText: pairs.map { $0.0 }.joined(separator: "\n"),
                translatedText: pairs.map { $0.1 }.joined(separator: "\n"),
                providerID: .volcengine
            )
        } catch {
            print(
                "volcengine image translation history skipped: \(error.localizedDescription)"
            )
        }
    }

    private func translate(
        segments: [OverlaySegment],
        resetProgress: Bool
    ) {
        translationTask?.cancel()
        markSegments(segments.map(\.id), phase: .translating)
        isTranslating = true
        if resetProgress {
            completedTranslationCount = 0
            totalTranslationCount = segments.count
        } else {
            completedTranslationCount = 0
            totalTranslationCount = segments.count
        }
        status("正在使用 Apple 本地翻译；连续 12 秒无结果会停止等待。", isError: false)
        progressStage = "本地翻译"

        translationTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await translateLocallyOrUseLegacyCloud(segments)
                isTranslating = false
                translationTask = nil
                progressStage = "已生成"
                hasGeneratedResult = true
                writeDebugArtifactsIfNeeded()
                if resetProgress {
                    await saveHistoryIfNeeded()
                } else {
                    status("翻译完成，已生成图片。", isError: false)
                }
            } catch is CancellationError {
                isTranslating = false
                translationTask = nil
                markTranslatingSegmentsAsRecognized()
            } catch {
                #if canImport(Translation)
                if let localError = error as? AppleOverlayTranslationError,
                   localError == .requestTimedOut {
                    isTranslating = false
                    translationTask = nil
                    markTranslatingSegmentsAsRecognized()
                    progressStage = "语言包未就绪"
                    status(localError.localizedDescription, isError: false)
                    return
                }
                #endif
                isTranslating = false
                translationTask = nil
                markSegments(segments.map(\.id), phase: .failed, errorMessage: error.localizedDescription)
                progressStage = "失败"
                status(error.localizedDescription, isError: true)
            }
        }
    }

    private func translateLocallyOrUseLegacyCloud(
        _ segments: [OverlaySegment]
    ) async throws {
        #if canImport(Translation)
        if #available(macOS 15.0, *),
           let appleTranslationCoordinator {
            for try await event in appleTranslationCoordinator.translate(
                segments: segments,
                targetLanguage: translationService.defaultTargetLanguage
            ) {
                try Task.checkCancellation()
                apply(event: event)
            }
            return
        }
        #endif

        progressStage = "云端兼容"
        for try await event in translationService.translateImageOverlaySegmentsIncrementally(
            segments,
            batchSize: 6
        ) {
            try Task.checkCancellation()
            apply(event: event)
        }
    }

    private func apply(event: ImageOverlayTranslationBatchEvent) {
        apply(results: event.results)
        completedTranslationCount += event.results.count
        status("翻译进度 \(completedTranslationCount)/\(totalTranslationCount)", isError: false)
    }

    private func saveHistoryIfNeeded() async {
        guard let session,
              let historyText = imageOverlayHistoryText(from: session) else {
            status("翻译完成，已生成图片。", isError: false)
            return
        }

        let fingerprint = historyText.sourceText + "\u{1F}" + historyText.translatedText
        guard savedHistoryFingerprint != fingerprint else {
            status("翻译完成，已生成图片。", isError: false)
            return
        }

        do {
            _ = try await translationService.recordImageOverlayHistory(
                sourceText: historyText.sourceText,
                translatedText: historyText.translatedText
            )
            savedHistoryFingerprint = fingerprint
            status("翻译完成，已生成图片并保存到历史。", isError: false)
        } catch {
            status("翻译完成，已生成图片，但保存历史失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func imageOverlayHistoryText(
        from session: ImageOverlaySession
    ) -> (sourceText: String, translatedText: String)? {
        let states = session.segmentStates
            .filter { !$0.isExcluded }
            .sorted { lhs, rhs in
                lhs.segment.readingOrder < rhs.segment.readingOrder
            }

        var sourceParts: [String] = []
        var translatedParts: [String] = []
        var hasTranslatedSegment = false

        for state in states {
            guard let result = state.translationResult else {
                continue
            }

            let source = state.segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else {
                continue
            }

            switch result.status {
            case .success, .fallbackUsed:
                let translated = result.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !translated.isEmpty else {
                    continue
                }
                sourceParts.append(source)
                translatedParts.append(translated)
                hasTranslatedSegment = true
            case .originalKept:
                sourceParts.append(source)
                translatedParts.append(source)
            case .failed:
                continue
            }
        }

        guard hasTranslatedSegment,
              !sourceParts.isEmpty,
              !translatedParts.isEmpty else {
            return nil
        }

        return (
            sourceParts.joined(separator: "\n"),
            translatedParts.joined(separator: "\n")
        )
    }

    private func apply(results: [ImageOverlayTranslationResult]) {
        guard var session else {
            return
        }

        for result in results {
            guard let index = session.segmentStates.firstIndex(where: { $0.id == result.segmentID }) else {
                continue
            }
            session.segmentStates[index].translationResult = result
            session.segmentStates[index].errorMessage = result.errorMessage
            if !session.segmentStates[index].isExcluded {
                session.segmentStates[index].phase = result.status.livePhase
            }
        }
        self.session = session
    }

    private func markSegments(
        _ ids: [String],
        phase: ImageOverlaySegmentPhase,
        errorMessage: String? = nil
    ) {
        guard var session else {
            return
        }

        let idSet = Set(ids)
        for index in session.segmentStates.indices where idSet.contains(session.segmentStates[index].id) {
            guard !session.segmentStates[index].isExcluded else {
                continue
            }
            session.segmentStates[index].phase = phase
            session.segmentStates[index].errorMessage = errorMessage
        }
        self.session = session
    }

    private func markTranslatingSegmentsAsRecognized() {
        guard var session else {
            return
        }

        for index in session.segmentStates.indices where session.segmentStates[index].phase == .translating {
            session.segmentStates[index].phase = session.segmentStates[index].translationResult?.status.livePhase ?? .recognized
        }
        self.session = session
    }

    private func exportImage() -> NSImage {
        if let volcengineResultImage {
            return volcengineResultImage
        }

        guard let session else {
            return NSImage(size: .zero)
        }

        let pairs = session.translatedExportPairs
        guard !pairs.isEmpty else {
            return session.originalImage
        }

        do {
            return try renderer.render(
                originalImage: session.originalImage,
                segments: pairs.map(\.segment),
                translationResults: pairs.map(\.result),
                style: .nativeReplace
            )
        } catch {
            return OverlayRegionPainter.renderLiveImage(
                originalImage: session.originalImage,
                regions: session.displayRegions,
                showOCRBoxes: false,
                selectedSegmentID: nil
            )
        }
    }

    private func writeDebugArtifactsIfNeeded() {
        guard let session, debugWriter.isEnabled else {
            return
        }

        _ = debugWriter.writeSessionArtifacts(
            originalImage: session.originalImage,
            ocrSnapshot: session.ocrSnapshot,
            segmentation: OverlaySegmentationSnapshot(
                textLines: session.textLines,
                overlaySegments: session.segments
            ),
            displayRegions: session.displayRegions,
            translationResults: session.segmentStates.compactMap(\.translationResult),
            renderer: renderer,
            force: false
        )
    }

    private func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func imagePixelSize(for image: NSImage) -> CGSize {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image.size
        }
        return CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
    }

    private static func currentVolcengineBillingDateRange(
        now: Date = Date()
    ) -> (from: Int, to: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")
            ?? TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let current = calendar.dateComponents([.year, .month, .day], from: now)
        let from = (current.year ?? 0) * 10_000 + (current.month ?? 0) * 100 + 1
        let to = (current.year ?? 0) * 10_000
            + (current.month ?? 0) * 100
            + (current.day ?? 0)
        return (from, to)
    }

    private func hasStartedTranslation(_ session: ImageOverlaySession) -> Bool {
        session.segmentStates.contains { state in
            switch state.phase {
            case .translated, .fallbackUsed, .failed, .translating:
                return true
            case .recognized, .originalKept, .excluded:
                return false
            }
        }
    }

    private func clearVolcengineState(keepOriginalSession: Bool) {
        volcengineResultImage = nil
        volcengineTextBlocks = []
        volcengineImageURL = nil
        useLocalFallbackAction = nil
        if !keepOriginalSession {
            session = nil
        }
    }

    private func status(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}

private struct ImageOverlayTranslationView: View {
    @ObservedObject var viewModel: ImageOverlayTranslationViewModel
    var onClose: () -> Void

    var body: some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *),
           let coordinator = viewModel.appleTranslationCoordinator {
            windowContent
                .modifier(
                    AppleOverlayTranslationTaskModifier(
                        coordinator: coordinator
                    )
                )
        } else {
            windowContent
        }
        #else
        windowContent
        #endif
    }

    private var windowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            toolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            content
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(
                viewModel.isVolcengineWorkflow ? "火山图片翻译 Beta" : "本地坐标翻译",
                systemImage: viewModel.isVolcengineWorkflow ? "cloud" : "text.viewfinder"
            )
                .font(.headline)

            Text(viewModel.workflowBadgeText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())

            if viewModel.isVolcengineWorkflow {
                Text(viewModel.monthlyUsageText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if viewModel.totalTranslationCount > 0 {
                Text(viewModel.translationProgressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(viewModel.progressStage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())

            if viewModel.isProcessing {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(viewModel.statusIsError ? Color.red : Color.secondary)
                    .lineLimit(1)
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if viewModel.isTranslating {
                Button {
                    viewModel.cancelTranslation()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            } else if viewModel.isVolcengineWorkflow && viewModel.canRetryVolcengine {
                Button {
                    viewModel.startTranslation()
                } label: {
                    Label("重试火山", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            } else if viewModel.canStartTranslation {
                Button {
                    viewModel.startTranslation()
                } label: {
                    Label("继续翻译", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            if viewModel.isVolcengineWorkflow {
                Button {
                    viewModel.useLocalFallback()
                } label: {
                    Label("本地坐标备用", systemImage: "desktopcomputer")
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canUseLocalFallback)

                Button {
                    viewModel.openVolcengineSettings()
                } label: {
                    Label("火山设置", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
            }

            Button {
                viewModel.copyOCRText()
            } label: {
                Label("复制 OCR", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canCopyOCRText)

            Button {
                viewModel.copyImage()
            } label: {
                Label("复制图片", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canExportImage)

            Button {
                viewModel.saveImage()
            } label: {
                Label("保存 PNG", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canExportImage)

            Button {
                viewModel.openDebugDirectory()
            } label: {
                Label("Debug", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canOpenDebugDirectory)

            Spacer()

            Button {
                viewModel.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.shouldShowPreview)

            Text("\(Int((viewModel.session?.zoomScale ?? 1) * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48)

            Button {
                viewModel.resetZoom()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.shouldShowPreview)

            Button {
                viewModel.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.shouldShowPreview)

        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.shouldShowPreview {
            HStack(spacing: 12) {
                previewCanvas
                if viewModel.selectedState != nil {
                    Divider()
                    inspector
                        .frame(width: 300)
                }
            }
        } else {
            processingView
        }
    }

    private var processingView: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            if viewModel.statusIsError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.red)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .scaleEffect(1.15)
            }

            Text(viewModel.progressStage)
                .font(.title3.weight(.semibold))

            if viewModel.totalTranslationCount > 0 {
                VStack(spacing: 8) {
                    ProgressView(
                        value: Double(viewModel.completedTranslationCount),
                        total: Double(max(viewModel.totalTranslationCount, 1))
                    )
                    .frame(width: 260)

                    Text(viewModel.translationProgressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.callout)
                    .foregroundStyle(viewModel.statusIsError ? Color.red : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 520)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var previewCanvas: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                let imageSize = viewModel.imagePixelSize
                let availableWidth = max(geometry.size.width - 24, 1)
                let availableHeight = max(geometry.size.height - 24, 1)
                let fitScale = min(
                    availableWidth / max(imageSize.width, 1),
                    availableHeight / max(imageSize.height, 1),
                    1
                )
                let effectiveScale = max(fitScale * (viewModel.session?.zoomScale ?? 1), 0.01)
                let scaledWidth = max(imageSize.width * effectiveScale, 1)
                let scaledHeight = max(imageSize.height * effectiveScale, 1)

                OverlayCanvasRepresentable(
                    image: viewModel.previewImage,
                    regions: viewModel.regions,
                    showOCRBoxes: false,
                    selectedSegmentID: nil,
                    drawTranslatedOverlays: true,
                    onSelect: { id in
                        viewModel.selectSegment(id)
                    }
                )
                .frame(width: scaledWidth, height: scaledHeight, alignment: .topLeading)
                .padding(12)
                .frame(
                    minWidth: availableWidth,
                    minHeight: availableHeight,
                    alignment: .topLeading
                )
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .overlay {
                if viewModel.isVolcengineWorkflow && viewModel.isTranslating {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("火山正在生成整图译文…")
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThickMaterial, in: Capsule())
                    .shadow(radius: 8, y: 3)
                }
            }
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let state = viewModel.selectedState {
                HStack {
                    Text(state.phase.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(state.segment.role.rawValue)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Text("原文")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(state.segment.sourceText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 72, maxHeight: 130)

                Text("译文")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(state.translationResult?.translatedText ?? "尚未翻译")
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .foregroundStyle(state.translationResult == nil ? .secondary : .primary)
                }
                .frame(minHeight: 72, maxHeight: 160)

                if let error = state.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .lineLimit(3)
                }

                HStack(spacing: 8) {
                    Button {
                        viewModel.retrySelected()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canRetrySelected)

                    Button {
                        viewModel.toggleSelectedExclusion()
                    } label: {
                        Label(state.isExcluded ? "恢复" : "排除", systemImage: state.isExcluded ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("点击图片中的 OCR 区域查看详情。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if viewModel.isVolcengineWorkflow {
                summaryChip("火山云端")
                summaryChip(viewModel.monthlyUsageText)
                if viewModel.volcengineTextBlockCount > 0 {
                    summaryChip("文字块 \(viewModel.volcengineTextBlockCount)")
                }
            } else {
                summaryChip("区域 \(viewModel.session?.segmentStates.count ?? 0)")
                summaryChip("成功 \(viewModel.session?.summary.successCount ?? 0)")
                summaryChip("备用 \(viewModel.session?.summary.fallbackCount ?? 0)")
                summaryChip("保留 \(viewModel.session?.summary.originalKeptCount ?? 0)")
                summaryChip("失败 \(viewModel.session?.summary.failedCount ?? 0)")
            }
            Spacer()
            Text(footerStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footerStatusText: String {
        if viewModel.isVolcengineWorkflow {
            if viewModel.isTranslating {
                return "正在上传整张截图并等待火山返回译图。"
            }
            if viewModel.canExportImage {
                return "云端译图仅保存在内存；手动保存的 PNG 不会自动删除。"
            }
            return "失败不会自动切换本地；可手动选择本地坐标备用。"
        }
        if viewModel.isTranslating {
            return "正在处理截图覆盖翻译，完成后会显示生成图片。"
        }
        if viewModel.session?.summary.successCount ?? 0 > 0 {
            return "预览、复制和保存使用同一套导出渲染结果。"
        }
        return "快捷键截图后会自动 OCR、翻译并生成结果。"
    }

    private func summaryChip(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

private struct OverlayCanvasRepresentable: NSViewRepresentable {
    var image: NSImage
    var regions: [OverlayDisplayRegion]
    var showOCRBoxes: Bool
    var selectedSegmentID: String?
    var drawTranslatedOverlays: Bool
    var onSelect: (String?) -> Void

    func makeNSView(context: Context) -> OverlayCanvasNSView {
        let view = OverlayCanvasNSView()
        view.onSelect = onSelect
        return view
    }

    func updateNSView(_ nsView: OverlayCanvasNSView, context: Context) {
        nsView.update(
            image: image,
            regions: regions,
            showOCRBoxes: showOCRBoxes,
            selectedSegmentID: selectedSegmentID,
            drawTranslatedOverlays: drawTranslatedOverlays,
            onSelect: onSelect
        )
    }
}

@MainActor
private final class OverlayCanvasNSView: NSView {
    private var image = NSImage(size: .zero)
    private var regions: [OverlayDisplayRegion] = []
    private var showOCRBoxes = true
    private var selectedSegmentID: String?
    private var drawTranslatedOverlays = true
    private var bitmap: NSBitmapImageRep?
    private var imageSize: CGSize = .zero
    var onSelect: (String?) -> Void = { _ in }

    func update(
        image: NSImage,
        regions: [OverlayDisplayRegion],
        showOCRBoxes: Bool,
        selectedSegmentID: String?,
        drawTranslatedOverlays: Bool,
        onSelect: @escaping (String?) -> Void
    ) {
        self.image = image
        self.regions = regions
        self.showOCRBoxes = showOCRBoxes
        self.selectedSegmentID = selectedSegmentID
        self.drawTranslatedOverlays = drawTranslatedOverlays
        self.onSelect = onSelect

        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            bitmap = NSBitmapImageRep(cgImage: cgImage)
            imageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        } else {
            bitmap = nil
            imageSize = image.size
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds)

        guard let bitmap else {
            return
        }

        OverlayRegionPainter.draw(
            regions: regions,
            bitmap: bitmap,
            imageSize: imageSize,
            canvasBounds: bounds,
            showOCRBoxes: showOCRBoxes,
            selectedSegmentID: selectedSegmentID,
            drawTranslatedOverlays: drawTranslatedOverlays
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let selected = OverlayRegionPainter.hitRegionID(
            at: point,
            regions: regions,
            imageSize: imageSize,
            canvasBounds: bounds
        )
        onSelect(selected)
    }
}
