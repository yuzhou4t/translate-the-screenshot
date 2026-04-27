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
    private let minimumBlockWidth: CGFloat = 44
    private let minimumBlockHeight: CGFloat = 24
    private let minimumFontSize: CGFloat = 11
    private let maximumFontSize: CGFloat = 30
    private let edgeInset: CGFloat = 4

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

            guard drawRect.width >= 8, drawRect.height >= 8 else {
                continue
            }

            let backgroundRect = overlayRect(
                for: drawRect,
                text: cleanedTranslation,
                within: imageRect
            )
            let textPadding = padding(for: style, rect: backgroundRect)
            let textRect = backgroundRect.insetBy(dx: textPadding.width, dy: textPadding.height)

            guard textRect.width > 12, textRect.height > 12 else {
                continue
            }

            let layout = fittedTextLayout(
                cleanedTranslation,
                in: textRect,
                style: style
            )

            drawBackground(style: style, in: backgroundRect)
            layout.attributedText.draw(in: layout.drawRect)
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

    private func overlayRect(
        for rect: CGRect,
        text: String,
        within bounds: CGRect
    ) -> CGRect {
        let prepared = rect
            .insetBy(dx: -3, dy: -3)
            .standardized

        let textLength = CGFloat(max(text.count, 1))
        let horizontalGrowth = min(
            max(prepared.height * min(textLength * 0.12, 2.8), 8),
            bounds.width * 0.16
        )
        let verticalGrowth = min(
            max(prepared.height * 0.18, 4),
            bounds.height * 0.06
        )

        let desiredWidth = max(minimumBlockWidth, prepared.width + horizontalGrowth)
        let desiredHeight = max(minimumBlockHeight, prepared.height + verticalGrowth)
        let centered = CGRect(
            x: prepared.midX - desiredWidth / 2,
            y: prepared.midY - desiredHeight / 2,
            width: desiredWidth,
            height: desiredHeight
        )

        return centered
            .clamped(to: bounds.insetBy(dx: edgeInset, dy: edgeInset))
            .integral
    }

    private func padding(
        for style: ScreenshotTranslationOverlayStyle,
        rect: CGRect
    ) -> CGSize {
        let baseHorizontal = min(max(rect.width * 0.1, 7), 18)
        let baseVertical = min(max(rect.height * 0.18, 5), 14)

        switch style {
        case .solid:
            return CGSize(width: baseHorizontal, height: baseVertical)
        case .translucent:
            return CGSize(width: baseHorizontal + 1.5, height: baseVertical + 0.5)
        case .bubble:
            return CGSize(width: baseHorizontal + 3, height: baseVertical + 2.5)
        }
    }

    private func drawBackground(
        style: ScreenshotTranslationOverlayStyle,
        in rect: CGRect
    ) {
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius(for: style, rect: rect), yRadius: cornerRadius(for: style, rect: rect))

        switch style {
        case .solid:
            NSColor(calibratedWhite: 0.985, alpha: 0.98).setFill()
            path.fill()
            NSColor(calibratedWhite: 0.78, alpha: 0.78).setStroke()
            path.lineWidth = 0.8
            path.stroke()
        case .translucent:
            NSColor(calibratedWhite: 1.0, alpha: 0.84).setFill()
            path.fill()
            NSColor(calibratedWhite: 0.72, alpha: 0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
        case .bubble:
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = CGSize(width: 0, height: -2)
            shadow.set()

            NSColor(calibratedRed: 1.0, green: 0.988, blue: 0.945, alpha: 0.96).setFill()
            path.fill()
            NSColor(calibratedRed: 0.88, green: 0.8, blue: 0.62, alpha: 0.72).setStroke()
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

    private func fittedTextLayout(
        _ text: String,
        in rect: CGRect,
        style: ScreenshotTranslationOverlayStyle
    ) -> FittedOverlayText {
        let preparedText = preparedOverlayText(text)
        let preferredLineBreakMode = lineBreakMode(for: preparedText)
        let baseFontSize = max(
            minimumFontSize,
            min(rect.height * 0.58, rect.width * 0.24, maximumFontSize)
        )
        let densityPenalty = min(CGFloat(max(preparedText.count - 10, 0)) * 0.18, 5)
        let maxFontSize = max(minimumFontSize, baseFontSize - densityPenalty)
        let textColor = foregroundColor(for: style)
        let textShadow = shadow(for: style)

        var chosenFont = font(size: maxFontSize)
        var chosenBounds = CGRect(origin: .zero, size: rect.size)

        for size in stride(from: maxFontSize, through: minimumFontSize, by: -0.5) {
            let candidateFont = font(size: size)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = preparedText.count <= 12 ? .center : .left
            paragraphStyle.lineBreakMode = preferredLineBreakMode
            paragraphStyle.lineSpacing = max(1, candidateFont.pointSize * 0.12)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: candidateFont,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle,
                .shadow: textShadow
            ]
            let candidate = NSAttributedString(string: preparedText, attributes: attributes)
            let measured = candidate.boundingRect(
                with: rect.size,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).integral

            if measured.width <= rect.width && measured.height <= rect.height {
                chosenFont = candidateFont
                chosenBounds = measured
                break
            }

            chosenFont = candidateFont
            chosenBounds = measured
        }

        let finalParagraphStyle = NSMutableParagraphStyle()
        finalParagraphStyle.alignment = preparedText.count <= 12 ? .center : .left
        finalParagraphStyle.lineBreakMode = preferredLineBreakMode
        finalParagraphStyle.lineSpacing = max(1, chosenFont.pointSize * 0.12)

        let finalAttributed = NSAttributedString(
            string: preparedText,
            attributes: [
                .font: chosenFont,
                .foregroundColor: textColor,
                .paragraphStyle: finalParagraphStyle,
                .shadow: textShadow
            ]
        )
        let finalBounds = finalAttributed.boundingRect(
            with: rect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral

        return FittedOverlayText(
            attributedText: finalAttributed,
            drawRect: centeredTextRect(
                measured: finalBounds.isEmpty ? chosenBounds : finalBounds,
                in: rect
            )
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

    private func shadow(for style: ScreenshotTranslationOverlayStyle) -> NSShadow {
        let shadow = NSShadow()
        switch style {
        case .solid:
            shadow.shadowColor = NSColor.white.withAlphaComponent(0.15)
            shadow.shadowBlurRadius = 0
            shadow.shadowOffset = .zero
        case .translucent:
            shadow.shadowColor = NSColor.white.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 1.2
            shadow.shadowOffset = .zero
        case .bubble:
            shadow.shadowColor = NSColor.white.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 0.8
            shadow.shadowOffset = .zero
        }
        return shadow
    }

    private func preparedOverlayText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lineBreakMode(for text: String) -> NSLineBreakMode {
        if containsProtectedToken(text) {
            return .byWordWrapping
        }

        return containsCJK(text) ? .byCharWrapping : .byWordWrapping
    }

    private func containsProtectedToken(_ text: String) -> Bool {
        let patterns = [
            #"https?://\S+"#,
            #"[A-Za-z_][A-Za-z0-9_./:-]{3,}"#,
            #"\d+(?:\.\d+)?(?:%|ms|s|MB|GB|KB|px|pt)?"#
        ]

        for pattern in patterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }

        return false
    }

    private func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
            (0x3400...0x4DBF).contains(Int(scalar.value))
        }
    }

    private func centeredTextRect(
        measured: CGRect,
        in rect: CGRect
    ) -> CGRect {
        let width = min(rect.width, max(measured.width, rect.width * 0.72))
        let height = min(rect.height, measured.height)
        let y = rect.minY + max((rect.height - height) / 2, 0)
        return CGRect(x: rect.minX, y: y, width: width, height: height).integral
    }
}

private struct FittedOverlayText {
    var attributedText: NSAttributedString
    var drawRect: CGRect
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
