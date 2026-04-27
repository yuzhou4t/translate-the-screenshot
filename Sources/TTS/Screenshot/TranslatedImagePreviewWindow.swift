import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TranslatedImagePreviewWindowController {
    private let viewModel: TranslatedImagePreviewViewModel
    private var window: NSWindow?

    init(renderer: ScreenshotTranslationOverlayRenderer) {
        self.viewModel = TranslatedImagePreviewViewModel(
            renderer: renderer
        )
    }

    func show(
        originalImage: NSImage,
        blocks: [OCRTextBlock],
        translations: [String],
        summary: ImageOverlayTranslationSummary,
        initialStyle: ScreenshotTranslationOverlayStyle = .solid,
        title: String = "截图翻译覆盖预览"
    ) throws {
        if window == nil {
            let rootView = TranslatedImagePreviewView(
                viewModel: viewModel,
                onClose: { [weak self] in
                    self?.window?.performClose(nil)
                }
            )
            let controller = NSHostingController(rootView: rootView)
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.title = title
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.setContentSize(NSSize(width: 1040, height: 820))
            newWindow.minSize = NSSize(width: 760, height: 560)
            newWindow.center()
            newWindow.isReleasedWhenClosed = false
            window = newWindow
        } else {
            window?.title = title
        }

        try viewModel.configure(
            originalImage: originalImage,
            blocks: blocks,
            translations: translations,
            summary: summary,
            initialStyle: initialStyle
        )

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class TranslatedImagePreviewViewModel: ObservableObject {
    @Published var renderedImage: NSImage = NSImage(size: .zero)
    @Published var selectedStyle: ScreenshotTranslationOverlayStyle = .solid
    @Published var zoomScale: CGFloat = 1
    @Published var statusMessage = ""
    @Published var statusIsError = false
    @Published var summary = ImageOverlayTranslationSummary(
        totalCount: 0,
        successCount: 0,
        fallbackCount: 0,
        originalKeptCount: 0,
        failedCount: 0
    )

    private let renderer: ScreenshotTranslationOverlayRenderer
    private var originalImage: NSImage?
    private var blocks: [OCRTextBlock] = []
    private var translations: [String] = []
    private var isApplyingStyle = false

    init(renderer: ScreenshotTranslationOverlayRenderer) {
        self.renderer = renderer
    }

    var imageSizeDescription: String {
        "\(Int(renderedImage.size.width)) × \(Int(renderedImage.size.height))"
    }

    func configure(
        originalImage: NSImage,
        blocks: [OCRTextBlock],
        translations: [String],
        summary: ImageOverlayTranslationSummary,
        initialStyle: ScreenshotTranslationOverlayStyle
    ) throws {
        self.originalImage = originalImage
        self.blocks = blocks
        self.translations = translations
        self.summary = summary
        zoomScale = 1
        statusMessage = ""
        statusIsError = false
        selectedStyle = initialStyle
        try rerender(using: initialStyle, statusMessage: "已生成 \(initialStyle.displayName) 预览")
    }

    func applyStyle(_ style: ScreenshotTranslationOverlayStyle) {
        guard !isApplyingStyle else {
            return
        }

        do {
            try rerender(using: style, statusMessage: "已切换为 \(style.displayName)")
        } catch {
            selectedStyle = style
            updateStatus(error.localizedDescription, isError: true)
        }
    }

    func regenerate() {
        do {
            try rerender(using: selectedStyle, statusMessage: "已重新生成预览")
        } catch {
            updateStatus(error.localizedDescription, isError: true)
        }
    }

    func copyImage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([renderedImage]) {
            updateStatus("已复制图片到剪贴板", isError: false)
        } else {
            updateStatus("复制图片失败，请重试。", isError: true)
        }
    }

    func saveImage() {
        guard let pngData = pngData(for: renderedImage) else {
            updateStatus("保存失败，无法导出 PNG。", isError: true)
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
            updateStatus("已保存 PNG", isError: false)
        } catch {
            updateStatus("保存失败：\(error.localizedDescription)", isError: true)
        }
    }

    func zoomIn() {
        zoomScale = min(zoomScale + 0.2, 4)
    }

    func zoomOut() {
        zoomScale = max(zoomScale - 0.2, 0.6)
    }

    func resetZoom() {
        zoomScale = 1
    }

    private func rerender(
        using style: ScreenshotTranslationOverlayStyle,
        statusMessage: String
    ) throws {
        guard let originalImage else {
            throw ScreenshotTranslationOverlayRendererError.imageLoadFailed
        }

        isApplyingStyle = true
        defer { isApplyingStyle = false }

        let image = try renderer.render(
            originalImage: originalImage,
            blocks: blocks,
            translations: translations,
            style: style
        )
        renderedImage = image
        selectedStyle = style
        updateStatus(statusMessage, isError: false)
    }

    private func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private func updateStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}

private struct TranslatedImagePreviewView: View {
    @ObservedObject var viewModel: TranslatedImagePreviewViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            previewCanvas
            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: viewModel.selectedStyle) { newStyle in
            viewModel.applyStyle(newStyle)
        }
    }

    private var summaryChips: some View {
        HStack(spacing: 8) {
            summaryChip("总块数 \(viewModel.summary.totalCount)")
            summaryChip("成功 \(viewModel.summary.successCount)")
            summaryChip("备用 \(viewModel.summary.fallbackCount)")
            summaryChip("保留原文 \(viewModel.summary.originalKeptCount)")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Label("翻译覆盖预览", systemImage: "photo.on.rectangle")
                .font(.headline)

            Text(viewModel.imageSizeDescription)
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
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("复制图片") {
                viewModel.copyImage()
            }
            .buttonStyle(.bordered)

            Button("保存为 PNG") {
                viewModel.saveImage()
            }
            .buttonStyle(.bordered)

            Picker("覆盖样式", selection: $viewModel.selectedStyle) {
                ForEach(ScreenshotTranslationOverlayStyle.allCases, id: \.self) { style in
                    Text(style.displayName)
                        .tag(style)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 150)

            Button("重新生成") {
                viewModel.regenerate()
            }
            .buttonStyle(.bordered)

            Spacer()

            HStack(spacing: 6) {
                Button {
                    viewModel.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.bordered)

                Text("\(Int(viewModel.zoomScale * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48)

                Button {
                    viewModel.resetZoom()
                } label: {
                    Text("100%")
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.bordered)
            }

            Button("关闭") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var previewCanvas: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                let imageSize = viewModel.renderedImage.size
                let availableWidth = max(geometry.size.width - 24, 1)
                let availableHeight = max(geometry.size.height - 24, 1)
                let fitScale = min(
                    availableWidth / max(imageSize.width, 1),
                    availableHeight / max(imageSize.height, 1),
                    1
                )
                let effectiveScale = max(fitScale * viewModel.zoomScale, 0.01)
                let scaledWidth = max(imageSize.width * effectiveScale, 1)
                let scaledHeight = max(imageSize.height * effectiveScale, 1)

                VStack {
                    Image(nsImage: viewModel.renderedImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: scaledWidth, height: scaledHeight, alignment: .topLeading)
                }
                .frame(
                    minWidth: availableWidth,
                    minHeight: max(availableHeight, scaledHeight),
                    alignment: .topLeading
                )
                .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            summaryChips
            Spacer()
            Text("切换样式或点击重新生成时，会重新调用覆盖渲染器。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

private extension ScreenshotTranslationOverlayStyle {
    var displayName: String {
        switch self {
        case .solid:
            "纯色覆盖"
        case .translucent:
            "半透明覆盖"
        case .bubble:
            "气泡覆盖"
        }
    }
}
