import AppKit
import CoreGraphics
import Foundation

enum ScreenshotTranslationOverlayStyle: String, CaseIterable, Codable {
    case solid
    case translucent
    case bubble
}

enum ScreenshotTranslationOverlayRendererError: LocalizedError {
    case imageLoadFailed
    case translationCountMismatch

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed:
            "无法读取原始截图。"
        case .translationCountMismatch:
            "覆盖渲染失败：文本块数量和译文数量不一致。"
        }
    }
}

struct ScreenshotTranslationOverlayRenderer: Sendable {
    func render(
        originalImage: NSImage,
        blocks: [OCRTextBlock],
        translations: [String],
        style: ScreenshotTranslationOverlayStyle = .solid
    ) throws -> NSImage {
        guard blocks.count == translations.count else {
            throw ScreenshotTranslationOverlayRendererError.translationCountMismatch
        }

        let imageSize = originalImage.size
        guard imageSize.width > 0,
              imageSize.height > 0,
              let sourceCGImage = originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScreenshotTranslationOverlayRendererError.imageLoadFailed
        }

        let outputImage = NSImage(size: imageSize)
        outputImage.lockFocus()
        defer { outputImage.unlockFocus() }

        let imageRect = CGRect(origin: .zero, size: imageSize)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: sourceCGImage, size: imageSize).draw(in: imageRect)

        for (block, translation) in zip(blocks, translations) {
            let cleanedTranslation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTranslation.isEmpty else {
                continue
            }

            let drawRect = convertToDrawingRect(block.boundingBox, imageSize: imageSize)
                .standardized
                .insetBy(dx: -2, dy: -2)
                .clamped(to: imageRect)

            guard drawRect.width >= 24, drawRect.height >= 14 else {
                continue
            }

            let backgroundRect = expandIfNeeded(drawRect, within: imageRect)
            let textPadding = padding(for: style, rect: backgroundRect)
            let textRect = backgroundRect.insetBy(dx: textPadding.width, dy: textPadding.height)

            guard textRect.width > 8, textRect.height > 8 else {
                continue
            }

            let attributedText = fittedAttributedText(
                cleanedTranslation,
                in: textRect,
                style: style
            )

            drawBackground(style: style, in: backgroundRect)
            attributedText.draw(in: textRect)
        }

        return outputImage
    }

    private func convertToDrawingRect(_ blockRect: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: blockRect.minX,
            y: imageSize.height - blockRect.minY - blockRect.height,
            width: blockRect.width,
            height: blockRect.height
        )
    }

    private func expandIfNeeded(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        let minHeight = max(rect.height, 28)
        let expandedHeight = max(minHeight, rect.height * 1.12)
        let expandedY = max(bounds.minY, rect.midY - expandedHeight / 2)
        let adjustedHeight = min(expandedHeight, bounds.maxY - expandedY)

        return CGRect(
            x: max(bounds.minX, rect.minX),
            y: expandedY,
            width: min(rect.width, bounds.maxX - rect.minX),
            height: adjustedHeight
        )
    }

    private func padding(
        for style: ScreenshotTranslationOverlayStyle,
        rect: CGRect
    ) -> CGSize {
        let baseHorizontal = min(max(rect.width * 0.08, 6), 18)
        let baseVertical = min(max(rect.height * 0.16, 4), 14)

        switch style {
        case .solid:
            return CGSize(width: baseHorizontal, height: baseVertical)
        case .translucent:
            return CGSize(width: baseHorizontal + 1, height: baseVertical)
        case .bubble:
            return CGSize(width: baseHorizontal + 3, height: baseVertical + 2)
        }
    }

    private func drawBackground(
        style: ScreenshotTranslationOverlayStyle,
        in rect: CGRect
    ) {
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius(for: style, rect: rect), yRadius: cornerRadius(for: style, rect: rect))

        switch style {
        case .solid:
            NSColor(calibratedWhite: 0.98, alpha: 0.96).setFill()
            path.fill()
        case .translucent:
            NSColor(calibratedWhite: 1.0, alpha: 0.72).setFill()
            path.fill()
            NSColor(calibratedWhite: 0.82, alpha: 0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        case .bubble:
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = CGSize(width: 0, height: -1)
            shadow.set()

            NSColor(calibratedRed: 1.0, green: 0.985, blue: 0.94, alpha: 0.94).setFill()
            path.fill()
            NSColor(calibratedRed: 0.9, green: 0.82, blue: 0.65, alpha: 0.72).setStroke()
            path.lineWidth = 1
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func cornerRadius(
        for style: ScreenshotTranslationOverlayStyle,
        rect: CGRect
    ) -> CGFloat {
        switch style {
        case .solid:
            return min(rect.height * 0.18, 8)
        case .translucent:
            return min(rect.height * 0.2, 10)
        case .bubble:
            return min(rect.height * 0.28, 14)
        }
    }

    private func fittedAttributedText(
        _ text: String,
        in rect: CGRect,
        style: ScreenshotTranslationOverlayStyle
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 1.5

        let minFontSize = max(10, min(rect.height * 0.22, 14))
        let maxFontSize = max(minFontSize, min(rect.height * 0.72, rect.width * 0.22, 30))
        let textColor = foregroundColor(for: style)

        var chosenFont = font(size: maxFontSize)
        for size in stride(from: maxFontSize, through: minFontSize, by: -1) {
            let candidateFont = font(size: size)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: candidateFont,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
            let candidate = NSAttributedString(string: text, attributes: attributes)
            let measured = candidate.boundingRect(
                with: rect.size,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).integral

            if measured.width <= rect.width && measured.height <= rect.height {
                chosenFont = candidateFont
                break
            }
        }

        let finalParagraphStyle = NSMutableParagraphStyle()
        finalParagraphStyle.alignment = .left
        finalParagraphStyle.lineBreakMode = .byWordWrapping
        finalParagraphStyle.lineSpacing = max(1, chosenFont.pointSize * 0.08)

        return NSAttributedString(
            string: text,
            attributes: [
                .font: chosenFont,
                .foregroundColor: textColor,
                .paragraphStyle: finalParagraphStyle
            ]
        )
    }

    private func font(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    private func foregroundColor(for style: ScreenshotTranslationOverlayStyle) -> NSColor {
        switch style {
        case .solid, .translucent:
            return NSColor(calibratedWhite: 0.08, alpha: 0.96)
        case .bubble:
            return NSColor(calibratedWhite: 0.14, alpha: 0.98)
        }
    }
}

private extension CGRect {
    func clamped(to bounds: CGRect) -> CGRect {
        let x = min(max(minX, bounds.minX), bounds.maxX)
        let y = min(max(minY, bounds.minY), bounds.maxY)
        let maxX = max(x, min(self.maxX, bounds.maxX))
        let maxY = max(y, min(self.maxY, bounds.maxY))
        return CGRect(x: x, y: y, width: max(0, maxX - x), height: max(0, maxY - y))
    }
}
