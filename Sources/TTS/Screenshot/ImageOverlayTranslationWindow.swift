import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ImageOverlayTranslationWindowController {
    private let viewModel: ImageOverlayTranslationViewModel
    private var window: NSWindow?

    init(
        renderer: ScreenshotTranslationOverlayRenderer,
        translationService: TranslationService,
        debugWriter: OverlayPipelineDebugWriter
    ) {
        viewModel = ImageOverlayTranslationViewModel(
            renderer: renderer,
            translationService: translationService,
            debugWriter: debugWriter
        )
    }

    func show(
        originalImage: NSImage,
        ocrSnapshot: OverlayOCRSnapshot,
        segmentation: OverlaySegmentationSnapshot,
        stage: ImageOverlayOCRStage,
        title: String = "截图覆盖翻译",
        autoStart: Bool = false
    ) {
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

    func showProgress(
        originalImage: NSImage,
        message: String,
        title: String = "截图覆盖翻译"
    ) {
        ensureWindow(title: title)
        viewModel.configureProgress(originalImage: originalImage, message: message)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow(title: String) {
        if window == nil {
            let rootView = ImageOverlayTranslationView(
                viewModel: viewModel,
                onClose: { [weak self] in
                    self?.viewModel.cancelTranslation()
                    self?.window?.performClose(nil)
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
            window = newWindow
        } else {
            window?.title = title
        }
    }
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

    private let renderer: ScreenshotTranslationOverlayRenderer
    private let translationService: TranslationService
    private let debugWriter: OverlayPipelineDebugWriter
    private var translationTask: Task<Void, Never>?

    init(
        renderer: ScreenshotTranslationOverlayRenderer,
        translationService: TranslationService,
        debugWriter: OverlayPipelineDebugWriter
    ) {
        self.renderer = renderer
        self.translationService = translationService
        self.debugWriter = debugWriter
    }

    var imagePixelSize: CGSize {
        guard let image = session?.originalImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .zero
        }
        return CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
    }

    var regions: [OverlayDisplayRegion] {
        session?.displayRegions ?? []
    }

    var previewImage: NSImage {
        exportImage()
    }

    var selectedState: ImageOverlaySegmentState? {
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
        guard !isTranslating,
              let session else {
            return false
        }
        return session.segmentStates.contains { $0.canTranslate && $0.translationResult == nil }
    }

    var canRetrySelected: Bool {
        guard !isTranslating, let selectedState else {
            return false
        }
        return selectedState.segment.shouldTranslate && !selectedState.isExcluded
    }

    var shouldShowResultImage: Bool {
        hasGeneratedResult && !isTranslating
    }

    var canExportImage: Bool {
        shouldShowResultImage
    }

    var canCopyOCRText: Bool {
        guard let text = session?.recognizedText else {
            return false
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canOpenDebugDirectory: Bool {
        guard let session else {
            return false
        }
        return !session.textLines.isEmpty || !session.segmentStates.isEmpty
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

    func startTranslation() {
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
        isTranslating = false
        markTranslatingSegmentsAsRecognized()
        status("已取消翻译。", isError: false)
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
        guard let text = session?.recognizedText,
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
        panel.title = "保存翻译覆盖图片"
        panel.nameFieldStringValue = "tts-overlay-\(Int(Date().timeIntervalSince1970)).png"
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
        status("正在翻译 \(segments.count) 个区域...", isError: false)
        progressStage = "翻译"

        translationTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                for try await event in translationService.translateImageOverlaySegmentsIncrementally(
                    segments,
                    batchSize: 6
                ) {
                    try Task.checkCancellation()
                    apply(results: event.results)
                    completedTranslationCount += event.results.count
                    status("翻译进度 \(completedTranslationCount)/\(totalTranslationCount)", isError: false)
                }
                isTranslating = false
                translationTask = nil
                progressStage = "已生成"
                hasGeneratedResult = true
                status("翻译完成，已生成图片。", isError: false)
                writeDebugArtifactsIfNeeded()
            } catch is CancellationError {
                isTranslating = false
                translationTask = nil
                markTranslatingSegmentsAsRecognized()
            } catch {
                isTranslating = false
                translationTask = nil
                markSegments(segments.map(\.id), phase: .failed, errorMessage: error.localizedDescription)
                progressStage = "失败"
                status(error.localizedDescription, isError: true)
            }
        }
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

    private func status(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}

private struct ImageOverlayTranslationView: View {
    @ObservedObject var viewModel: ImageOverlayTranslationViewModel
    var onClose: () -> Void

    var body: some View {
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
            Label("截图覆盖翻译", systemImage: "text.viewfinder")
                .font(.headline)

            Text(viewModel.session?.ocrStage.displayName ?? "等待 OCR")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())

            if viewModel.totalTranslationCount > 0 {
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
            Button {
                viewModel.startTranslation()
            } label: {
                Label("翻译", systemImage: "translate")
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canStartTranslation)

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
            .disabled(!viewModel.shouldShowResultImage)

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
            .disabled(!viewModel.shouldShowResultImage)

            Button {
                viewModel.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.shouldShowResultImage)

        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.shouldShowResultImage {
            HStack(spacing: 12) {
                previewCanvas
                Divider()
                inspector
                    .frame(width: 300)
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
                    drawTranslatedOverlays: false,
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
            summaryChip("区域 \(viewModel.session?.segmentStates.count ?? 0)")
            summaryChip("成功 \(viewModel.session?.summary.successCount ?? 0)")
            summaryChip("备用 \(viewModel.session?.summary.fallbackCount ?? 0)")
            summaryChip("保留 \(viewModel.session?.summary.originalKeptCount ?? 0)")
            summaryChip("失败 \(viewModel.session?.summary.failedCount ?? 0)")
            Spacer()
            Text(footerStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footerStatusText: String {
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
