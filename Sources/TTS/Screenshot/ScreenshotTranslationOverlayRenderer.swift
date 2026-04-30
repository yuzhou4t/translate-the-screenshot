import AppKit
import CoreGraphics
import Foundation

enum ScreenshotTranslationOverlayStyle: String, CaseIterable, Codable {
    case solid
    case translucent
    case bubble
    case nativeReplace
}

enum ScreenshotTranslationOverlayRendererError: LocalizedError {
    case imageLoadFailed
    case translationCountMismatch

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed:
            "无法读取原始截图。"
        case .translationCountMismatch:
            "覆盖渲染失败：语义段数量和译文数量不一致。"
        }
    }
}

struct ScreenshotTranslationOverlayRenderer: Sendable {
    private let minimumBlockWidth: CGFloat = 44
    private let minimumBlockHeight: CGFloat = 24
    private let minimumFontSize: CGFloat = 11
    private let maximumFontSize: CGFloat = 30
    private let nativeReplaceMinimumFontSize: CGFloat = 10
    private let nativeReplaceFallbackMinimumWidth: CGFloat = 26
    private let nativeReplaceFallbackMinimumHeight: CGFloat = 16
    private let edgeInset: CGFloat = 4

    func render(
        originalImage: NSImage,
        segments: [OverlaySegment],
        translations: [String],
        style: ScreenshotTranslationOverlayStyle = .solid
    ) throws -> NSImage {
        guard segments.count == translations.count else {
            throw ScreenshotTranslationOverlayRendererError.translationCountMismatch
        }

        let translationResults = zip(segments, translations).map { segment, translation in
            ImageOverlayTranslationResult(
                segmentID: segment.id,
                sourceText: segment.sourceText,
                translatedText: translation,
                lineTranslations: [],
                status: .success,
                errorMessage: nil
            )
        }

        return try render(
            originalImage: originalImage,
            segments: segments,
            translationResults: translationResults,
            style: style
        )
    }

    func render(
        originalImage: NSImage,
        segments: [OverlaySegment],
        translationResults: [ImageOverlayTranslationResult],
        style: ScreenshotTranslationOverlayStyle = .solid
    ) throws -> NSImage {
        guard segments.count == translationResults.count else {
            throw ScreenshotTranslationOverlayRendererError.translationCountMismatch
        }

        guard let sourceCGImage = originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScreenshotTranslationOverlayRendererError.imageLoadFailed
        }
        let imageSize = CGSize(width: CGFloat(sourceCGImage.width), height: CGFloat(sourceCGImage.height))
        guard imageSize.width > 0, imageSize.height > 0 else {
            throw ScreenshotTranslationOverlayRendererError.imageLoadFailed
        }

        let outputImage = NSImage(size: imageSize)
        outputImage.lockFocus()
        defer { outputImage.unlockFocus() }

        let imageRect = CGRect(origin: .zero, size: imageSize)
        let bitmap = NSBitmapImageRep(cgImage: sourceCGImage)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: sourceCGImage, size: imageSize).draw(in: imageRect)

        if style == .nativeReplace {
            var nativePlans: [NativeReplaceRenderPlan] = []
            var legacyPairs: [(translation: String, rect: CGRect)] = []

            for (segment, result) in zip(segments, translationResults) {
                let cleanedTranslation = result.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanedTranslation.isEmpty else {
                    continue
                }

                let drawRect = convertToDrawingRect(segment.boundingBox, imageSize: imageSize)
                    .standardized

                guard drawRect.width >= 8, drawRect.height >= 8 else {
                    continue
                }

                if let plan = makeNativeReplacePlan(
                    segment: segment,
                    result: result,
                    segmentRect: drawRect,
                    imageRect: imageRect,
                    imageSize: imageSize,
                    bitmap: bitmap
                ) {
                    nativePlans.append(plan)
                } else {
                    legacyPairs.append((cleanedTranslation, drawRect))
                }
            }

            for plan in nativePlans {
                for fill in plan.eraseFills {
                    drawNativeReplaceBackground(
                        in: fill.rect,
                        fillColor: fill.color,
                        complexBackground: plan.complexBackground
                    )
                }
            }

            for plan in nativePlans {
                if !renderNativeReplaceText(plan) {
                    legacyPairs.append((plan.translation, plan.segmentRect))
                }
            }

            for pair in legacyPairs {
                renderLegacySegment(
                    translation: pair.translation,
                    drawRect: pair.rect,
                    imageRect: imageRect,
                    style: .translucent
                )
            }

            return outputImage
        }

        for (segment, result) in zip(segments, translationResults) {
            let cleanedTranslation = result.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTranslation.isEmpty else {
                continue
            }

            let drawRect = convertToDrawingRect(segment.boundingBox, imageSize: imageSize)
                .standardized

            guard drawRect.width >= 8, drawRect.height >= 8 else {
                continue
            }

            renderLegacySegment(
                translation: cleanedTranslation,
                drawRect: drawRect,
                imageRect: imageRect,
                style: style
            )
        }

        return outputImage
    }

    private func renderLegacySegment(
        translation: String,
        drawRect: CGRect,
        imageRect: CGRect,
        style: ScreenshotTranslationOverlayStyle
    ) {
            let backgroundRect = overlayRect(
                for: drawRect,
                text: translation,
                within: imageRect
            )
            let textPadding = padding(for: style, rect: backgroundRect)
            let textRect = backgroundRect.insetBy(dx: textPadding.width, dy: textPadding.height)

            guard textRect.width > 12, textRect.height > 12 else {
                return
            }

            let layout = fittedTextLayout(
                translation,
                in: textRect,
                style: style
            )

            drawBackground(style: style, in: backgroundRect)
            layout.attributedText.draw(in: layout.drawRect)
    }

    private func makeNativeReplacePlan(
        segment: OverlaySegment,
        result: ImageOverlayTranslationResult,
        segmentRect: CGRect,
        imageRect: CGRect,
        imageSize: CGSize,
        bitmap: NSBitmapImageRep
    ) -> NativeReplaceRenderPlan? {
        let translation = result.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty else {
            return nil
        }

        let sourceEraseBoxes = segment.reflowPreferred
            ? [reflowSourceRect(for: segment)]
            : (!segment.eraseBoxes.isEmpty
                ? segment.eraseBoxes
                : (segment.lineBoxes.isEmpty ? [segment.boundingBox] : segment.lineBoxes))
        let drawingLineBoxes = sourceEraseBoxes
            .map { convertToDrawingRect($0, imageSize: imageSize).standardized }
            .filter { $0.width >= 2 && $0.height >= 2 }

        guard !drawingLineBoxes.isEmpty else {
            return nil
        }

        let eraseRects = drawingLineBoxes
            .map { precisionEraseRect($0, imageSize: imageSize) }
            .filter { $0.width >= 4 && $0.height >= 4 }

        guard !eraseRects.isEmpty else {
            return nil
        }

        let tooSmall = segmentRect.width < nativeReplaceFallbackMinimumWidth ||
            segmentRect.height < nativeReplaceFallbackMinimumHeight
        if tooSmall {
            return nil
        }

        let overallBackground = averageBackgroundColor(for: eraseRects, bitmap: bitmap, imageSize: imageSize)
        guard let backgroundColor = overallBackground else {
            return nil
        }

        let complexBackground = eraseRects.contains {
            isComplexBackground(around: $0, in: bitmap, imageSize: imageSize)
        }

        let sourceLineRects = effectiveLineRects(for: segment, imageSize: imageSize)
        let baseTextRect = segment.reflowPreferred
            ? reflowTextRect(segmentRect: segmentRect, eraseRects: eraseRects, imageRect: imageRect)
            : nativeReplaceTextRect(
                segmentRect: segmentRect,
                eraseRects: eraseRects,
                lineRects: sourceLineRects,
                imageRect: imageRect
            )

        guard baseTextRect.width > 8, baseTextRect.height > 8 else {
            return nil
        }

        let textColor = estimateTextColor(for: backgroundColor)
        let eraseFills = eraseRects.map {
            NativeEraseFill(
                rect: $0,
                color: sampleBackgroundColor(around: $0, in: bitmap, imageSize: imageSize) ?? backgroundColor
            )
        }

        return NativeReplaceRenderPlan(
            segment: segment,
            result: result,
            translation: translation,
            segmentRect: segmentRect,
            imageRect: imageRect,
            imageSize: imageSize,
            eraseRects: eraseRects,
            lineRects: sourceLineRects,
            baseTextRect: baseTextRect,
            eraseFills: eraseFills,
            backgroundColor: backgroundColor,
            textColor: textColor,
            complexBackground: complexBackground,
            reflow: segment.reflowPreferred
        )
    }

    private func renderNativeReplaceText(_ plan: NativeReplaceRenderPlan) -> Bool {
        if plan.reflow {
            return renderReflowNativeReplaceText(plan)
        }

        let validLineTranslations = alignedLineTranslations(
            from: plan.result.lineTranslations,
            for: plan.segment
        )

        if let validLineTranslations,
           renderLineAlignedNativeReplaceSegment(
                segment: plan.segment,
                lineTranslations: validLineTranslations,
                lineRects: plan.lineRects,
                segmentRect: plan.segmentRect,
                imageRect: plan.imageRect,
                textColor: plan.textColor,
                imageSize: plan.imageSize
           ) {
            return true
        }

        let initialLayout = fittedNativeReplaceTextLayout(
            plan.translation,
            in: plan.baseTextRect,
            segment: plan.segment,
            textColor: plan.textColor
        )

        if initialLayout.fitsWithinRect && initialLayout.fontSize >= nativeReplaceMinimumFontSize {
            initialLayout.attributedText.draw(in: initialLayout.drawRect)
            return true
        }

        let expandedTextRect = expandedRect(
            plan.baseTextRect,
            padding: max(min(plan.segmentRect.height * 0.14, 6), 2),
            imageSize: plan.imageSize
        )
        .clamped(to: plan.imageRect.insetBy(dx: edgeInset, dy: edgeInset))

        guard expandedTextRect.width > plan.baseTextRect.width || expandedTextRect.height > plan.baseTextRect.height else {
            return false
        }

        let expandedLayout = fittedNativeReplaceTextLayout(
            plan.translation,
            in: expandedTextRect,
            segment: plan.segment,
            textColor: plan.textColor
        )

        guard expandedLayout.fitsWithinRect,
              expandedLayout.fontSize >= nativeReplaceMinimumFontSize else {
            return false
        }

        expandedLayout.attributedText.draw(in: expandedLayout.drawRect)
        return true
    }

    private func renderReflowNativeReplaceText(_ plan: NativeReplaceRenderPlan) -> Bool {
        let layout = fittedReflowTextLayout(
            plan.translation,
            in: plan.baseTextRect,
            segment: plan.segment,
            textColor: plan.textColor
        )

        guard layout.fitsWithinRect,
              layout.fontSize >= nativeReplaceMinimumFontSize else {
            return false
        }

        layout.attributedText.draw(in: layout.drawRect)
        return true
    }

    private func convertToDrawingRect(_ segmentRect: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: segmentRect.minX,
            y: imageSize.height - segmentRect.minY - segmentRect.height,
            width: segmentRect.width,
            height: segmentRect.height
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
        case .translucent, .nativeReplace:
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
        case .translucent, .nativeReplace:
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
        case .translucent, .nativeReplace:
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
            ),
            fontSize: chosenFont.pointSize,
            fitsWithinRect: finalBounds.width <= rect.width && finalBounds.height <= rect.height
        )
    }

    private func font(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    private func expandedRect(
        _ rect: CGRect,
        padding: CGFloat,
        imageSize: CGSize
    ) -> CGRect {
        CGRect(origin: .zero, size: imageSize)
            .insetBy(dx: edgeInset, dy: edgeInset)
            .intersection(rect.insetBy(dx: -padding, dy: -padding))
            .integral
    }

    private func precisionEraseRect(
        _ rect: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        let horizontalPadding = min(max(rect.height * 0.08, 1), 3)
        let verticalPadding = min(max(rect.height * 0.06, 0.75), 2)
        return CGRect(origin: .zero, size: imageSize)
            .insetBy(dx: edgeInset, dy: edgeInset)
            .intersection(rect.insetBy(dx: -horizontalPadding, dy: -verticalPadding))
            .integral
    }

    private func reflowSourceRect(for segment: OverlaySegment) -> CGRect {
        let box = segment.boundingBox.standardized
        let height = max(box.height, segment.lineBoxes.map(\.height).max() ?? box.height)
        let compact = compactTextLength(segment.sourceText) <= 24
        let horizontalPadding = compact
            ? max(min(height * 0.18, 8), 2)
            : max(min(height * 0.35, 16), 5)
        let verticalPadding = compact
            ? max(min(height * 0.12, 5), 1.5)
            : max(min(height * 0.22, 10), 3)
        return box.insetBy(dx: -horizontalPadding, dy: -verticalPadding).standardized
    }

    private func sampleBackgroundColor(
        around rect: CGRect,
        in bitmap: NSBitmapImageRep,
        imageSize: CGSize
    ) -> NSColor? {
        let colors = sampledColors(around: rect, in: bitmap, imageSize: imageSize)
        guard !colors.isEmpty else {
            return nil
        }

        let rgbaColors = colors.compactMap(rgbaComponents)
        guard !rgbaColors.isEmpty else {
            return nil
        }

        let dominant = dominantColorComponents(from: rgbaColors)

        return NSColor(
            calibratedRed: dominant.red,
            green: dominant.green,
            blue: dominant.blue,
            alpha: 1
        )
    }

    private func averageBackgroundColor(
        for rects: [CGRect],
        bitmap: NSBitmapImageRep,
        imageSize: CGSize
    ) -> NSColor? {
        let colors = rects.compactMap { sampleBackgroundColor(around: $0, in: bitmap, imageSize: imageSize) }
        guard !colors.isEmpty else {
            return nil
        }

        let rgbaColors = colors.compactMap(rgbaComponents)
        guard !rgbaColors.isEmpty else {
            return nil
        }

        let dominant = dominantColorComponents(from: rgbaColors)

        return NSColor(calibratedRed: dominant.red, green: dominant.green, blue: dominant.blue, alpha: 1)
    }

    private func estimateTextColor(for background: NSColor) -> NSColor {
        let components = rgbaComponents(background) ?? (red: 1, green: 1, blue: 1, alpha: 1)
        let luminance = (0.2126 * components.red) + (0.7152 * components.green) + (0.0722 * components.blue)
        return luminance < 0.58
            ? NSColor(calibratedWhite: 0.98, alpha: 0.98)
            : NSColor(calibratedWhite: 0.08, alpha: 0.98)
    }

    private func isComplexBackground(
        around rect: CGRect,
        in bitmap: NSBitmapImageRep,
        imageSize: CGSize
    ) -> Bool {
        let colors = sampledColors(around: rect, in: bitmap, imageSize: imageSize)
        let rgbaColors = colors.compactMap(rgbaComponents)
        guard rgbaColors.count >= 4 else {
            return true
        }

        let averageRed = rgbaColors.map(\.red).reduce(0, +) / CGFloat(rgbaColors.count)
        let averageGreen = rgbaColors.map(\.green).reduce(0, +) / CGFloat(rgbaColors.count)
        let averageBlue = rgbaColors.map(\.blue).reduce(0, +) / CGFloat(rgbaColors.count)
        let averageLuminance = rgbaColors
            .map { (0.2126 * $0.red) + (0.7152 * $0.green) + (0.0722 * $0.blue) }
            .reduce(0, +) / CGFloat(rgbaColors.count)

        let averageDistance = rgbaColors
            .map {
                abs($0.red - averageRed) +
                    abs($0.green - averageGreen) +
                    abs($0.blue - averageBlue)
            }
            .reduce(0, +) / CGFloat(rgbaColors.count)
        let luminanceSpread = rgbaColors
            .map { abs(((0.2126 * $0.red) + (0.7152 * $0.green) + (0.0722 * $0.blue)) - averageLuminance) }
            .reduce(0, +) / CGFloat(rgbaColors.count)

        return averageDistance > 0.25 || luminanceSpread > 0.11
    }

    private func fitFontSize(
        for text: String,
        in rect: CGRect,
        baseFont: NSFont
    ) -> CGFloat {
        let preparedText = preparedOverlayText(text)
        let baseSize = min(baseFont.pointSize, maximumFontSize)

        for size in stride(from: baseSize, through: minimumFontSize, by: -0.5) {
            let candidateFont = font(size: size)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = preparedText.count <= 12 ? .center : .left
            paragraphStyle.lineBreakMode = lineBreakMode(for: preparedText)
            paragraphStyle.lineSpacing = max(1, candidateFont.pointSize * 0.12)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: candidateFont,
                .paragraphStyle: paragraphStyle
            ]
            let measured = NSAttributedString(string: preparedText, attributes: attributes)
                .boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
                .integral

            if measured.width <= rect.width && measured.height <= rect.height {
                return size
            }
        }

        return minimumFontSize
    }

    private func drawNativeReplaceBackground(
        in rect: CGRect,
        fillColor: NSColor,
        complexBackground: Bool
    ) {
        let color = fillColor.withAlphaComponent(1)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: min(rect.height * 0.04, 1.5),
            yRadius: min(rect.height * 0.04, 1.5)
        )
        color.setFill()
        path.fill()

        if complexBackground {
            color.blended(withFraction: 0.12, of: .white)?.setStroke()
            path.lineWidth = 0.35
            path.stroke()
        }
    }

    private func fittedNativeReplaceTextLayout(
        _ text: String,
        in rect: CGRect,
        segment: OverlaySegment,
        textColor: NSColor
    ) -> FittedOverlayText {
        let preparedText = preparedOverlayText(text)
        let preferredLineBreakMode = lineBreakMode(for: preparedText)
        let estimatedHeight = estimatedNativeReplaceFontHeight(for: segment, fallbackRect: rect)
        let baseFont = font(size: min(maximumFontSize, max(estimatedHeight * 0.88, nativeReplaceMinimumFontSize)))
        let fittedFontSize = fitFontSize(for: preparedText, in: rect, baseFont: baseFont)
        let textShadow = nativeReplaceShadow(for: textColor)
        let alignment: NSTextAlignment = preferredTextAlignment(for: segment, text: preparedText)

        var chosenFont = font(size: fittedFontSize)
        var chosenBounds = CGRect(origin: .zero, size: rect.size)
        var didFit = false

        for size in stride(from: fittedFontSize, through: minimumFontSize, by: -0.5) {
            let candidateFont = font(size: size)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = alignment
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
                didFit = true
                break
            }

            chosenFont = candidateFont
            chosenBounds = measured
        }

        let finalParagraphStyle = NSMutableParagraphStyle()
        finalParagraphStyle.alignment = alignment
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
            drawRect: positionedTextRect(
                measured: finalBounds.isEmpty ? chosenBounds : finalBounds,
                in: rect
                ,
                alignment: alignment
            ),
            fontSize: chosenFont.pointSize,
            fitsWithinRect: didFit
        )
    }

    private func fittedReflowTextLayout(
        _ text: String,
        in rect: CGRect,
        segment: OverlaySegment,
        textColor: NSColor
    ) -> FittedOverlayText {
        let preparedText = preparedOverlayText(text)
        let preferredLineBreakMode = lineBreakMode(for: preparedText)
        let sourceHeight = max(segment.lineBoxes.map(\.height).max() ?? rect.height, nativeReplaceMinimumFontSize)
        let sourceLineCount = max(segment.lines.count, 1)
        let targetLineCount = max(sourceLineCount, Int(ceil(CGFloat(compactTextLength(preparedText)) / max(rect.width / max(sourceHeight * 0.9, 10), 1))))
        let baseSize = min(maximumFontSize, max(sourceHeight * 0.95, nativeReplaceMinimumFontSize))
        let minSize = max(nativeReplaceMinimumFontSize, min(sourceHeight * 0.62, 14))
        let alignment: NSTextAlignment = segment.role == .title ? .center : .left
        let textShadow = nativeReplaceShadow(for: textColor)

        var chosenFont = font(size: baseSize)
        var chosenBounds = CGRect(origin: .zero, size: rect.size)
        var didFit = false

        for size in stride(from: baseSize, through: minSize, by: -0.5) {
            let candidateFont = font(size: size)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = alignment
            paragraphStyle.lineBreakMode = preferredLineBreakMode
            paragraphStyle.lineSpacing = max(1, candidateFont.pointSize * 0.16)
            paragraphStyle.maximumLineHeight = candidateFont.pointSize * 1.32

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

            chosenFont = candidateFont
            chosenBounds = measured
            if measured.width <= rect.width,
               measured.height <= rect.height,
               measured.height <= rect.height * CGFloat(max(targetLineCount, 1)) {
                didFit = true
                break
            }
        }

        let finalParagraphStyle = NSMutableParagraphStyle()
        finalParagraphStyle.alignment = alignment
        finalParagraphStyle.lineBreakMode = preferredLineBreakMode
        finalParagraphStyle.lineSpacing = max(1, chosenFont.pointSize * 0.16)
        finalParagraphStyle.maximumLineHeight = chosenFont.pointSize * 1.32

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
            drawRect: positionedTextRect(
                measured: finalBounds.isEmpty ? chosenBounds : finalBounds,
                in: rect,
                alignment: alignment
            ),
            fontSize: chosenFont.pointSize,
            fitsWithinRect: didFit || finalBounds.height <= rect.height
        )
    }

    private func alignedLineTranslations(
        from lineTranslations: [SegmentLineTranslation],
        for segment: OverlaySegment
    ) -> [SegmentLineTranslation]? {
        guard !lineTranslations.isEmpty,
              lineTranslations.count == segment.lines.count else {
            return nil
        }

        let sorted = lineTranslations.sorted { $0.lineIndex < $1.lineIndex }
        for (expectedIndex, item) in sorted.enumerated() {
            let cleaned = item.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard item.lineIndex == expectedIndex, !cleaned.isEmpty else {
                return nil
            }
        }
        return sorted
    }

    private func renderLineAlignedNativeReplaceSegment(
        segment: OverlaySegment,
        lineTranslations: [SegmentLineTranslation],
        lineRects: [CGRect],
        segmentRect: CGRect,
        imageRect: CGRect,
        textColor: NSColor,
        imageSize: CGSize
    ) -> Bool {
        guard !lineRects.isEmpty,
              lineRects.count == lineTranslations.count else {
            return false
        }

        var layouts: [FittedOverlayText] = []
        layouts.reserveCapacity(lineRects.count)

        for (index, lineTranslation) in lineTranslations.enumerated() {
            let baseLineRect = lineRects[index]
            let textRect = perLineTextRect(
                for: baseLineRect,
                segmentRect: segmentRect,
                imageRect: imageRect,
                imageSize: imageSize
            )

            guard textRect.width > 6, textRect.height > 6 else {
                return false
            }

            let lineSegment = OverlaySegment(
                id: segment.id,
                sourceBlockIDs: segment.sourceBlockIDs,
                sourceAtomIDs: segment.sourceAtomIDs,
                sourceText: segment.lines[index].text,
                lines: [segment.lines[index]],
                boundingBox: segment.lineBoxes.indices.contains(index) ? segment.lineBoxes[index] : segment.boundingBox,
                lineBoxes: segment.lineBoxes.indices.contains(index) ? [segment.lineBoxes[index]] : [segment.boundingBox],
                eraseBoxes: [],
                role: segment.role,
                readingOrder: segment.readingOrder,
                shouldTranslate: segment.shouldTranslate
            )

            let layout = fittedNativeReplaceTextLayout(
                lineTranslation.translation,
                in: textRect,
                segment: lineSegment,
                textColor: textColor
            )

            if layout.fitsWithinRect,
               layout.fontSize >= nativeReplaceMinimumFontSize {
                layouts.append(layout)
                continue
            }

            let relaxedTextRect = relaxedPerLineTextRect(
                for: baseLineRect,
                segmentRect: segmentRect,
                imageRect: imageRect,
                imageSize: imageSize
            )
            let relaxedLayout = fittedNativeReplaceTextLayout(
                lineTranslation.translation,
                in: relaxedTextRect,
                segment: lineSegment,
                textColor: textColor
            )

            guard relaxedLayout.fitsWithinRect,
                  relaxedLayout.fontSize >= nativeReplaceMinimumFontSize else {
                return false
            }

            layouts.append(relaxedLayout)
        }

        for layout in layouts {
            layout.attributedText.draw(in: layout.drawRect)
        }

        return true
    }

    private func perLineTextRect(
        for lineRect: CGRect,
        segmentRect: CGRect,
        imageRect: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        let expanded = expandedRect(
            lineRect,
            padding: max(min(lineRect.height * 0.16, 4), 1.5),
            imageSize: imageSize
        )
        let anchor = expanded.intersection(segmentRect.insetBy(dx: -1.5, dy: -1.5))
        let resolved = (!anchor.isNull && anchor.width > 6 && anchor.height > 6) ? anchor : expanded
        return resolved.clamped(to: imageRect.insetBy(dx: edgeInset, dy: edgeInset)).integral
    }

    private func relaxedPerLineTextRect(
        for lineRect: CGRect,
        segmentRect: CGRect,
        imageRect: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        let horizontalPadding = max(min(segmentRect.height * 0.16, 10), 4)
        let verticalPadding = max(min(lineRect.height * 0.18, 4), 1.5)
        let relaxed = CGRect(
            x: min(lineRect.minX, segmentRect.minX) - horizontalPadding,
            y: lineRect.minY - verticalPadding,
            width: max(lineRect.width, segmentRect.width) + horizontalPadding * 2,
            height: lineRect.height + verticalPadding * 2
        )
        return expandedRect(relaxed, padding: 0, imageSize: imageSize)
            .clamped(to: imageRect.insetBy(dx: edgeInset, dy: edgeInset))
            .integral
    }

    private func foregroundColor(for style: ScreenshotTranslationOverlayStyle) -> NSColor {
        switch style {
        case .solid, .translucent, .nativeReplace:
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
        case .translucent, .nativeReplace:
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

    private func nativeReplaceShadow(for textColor: NSColor) -> NSShadow {
        let shadow = NSShadow()
        let isLightText = ((rgbaComponents(textColor)?.red ?? 0) > 0.7)
        shadow.shadowColor = isLightText
            ? NSColor.black.withAlphaComponent(0.28)
            : NSColor.white.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 0.8
        shadow.shadowOffset = .zero
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

    private func positionedTextRect(
        measured: CGRect,
        in rect: CGRect,
        alignment: NSTextAlignment
    ) -> CGRect {
        let width = min(rect.width, max(measured.width, min(rect.width * 0.82, measured.width + 2)))
        let height = min(rect.height, measured.height)
        let y = rect.minY + max((rect.height - height) / 2, 0)
        let x: CGFloat
        switch alignment {
        case .center:
            x = rect.minX + max((rect.width - width) / 2, 0)
        case .right:
            x = rect.maxX - width
        default:
            x = rect.minX
        }
        return CGRect(x: x, y: y, width: width, height: height).integral
    }

    private func effectiveLineRects(
        for segment: OverlaySegment,
        imageSize: CGSize
    ) -> [CGRect] {
        let boxes = segment.lineBoxes.isEmpty ? [segment.boundingBox] : segment.lineBoxes
        return boxes
            .map { convertToDrawingRect($0, imageSize: imageSize).standardized }
            .filter { $0.width >= 2 && $0.height >= 2 }
    }

    private func nativeReplaceTextRect(
        segmentRect: CGRect,
        eraseRects: [CGRect],
        lineRects: [CGRect],
        imageRect: CGRect
    ) -> CGRect {
        let textAnchorRects = lineRects.isEmpty ? eraseRects : lineRects
        let anchorUnion = textAnchorRects.dropFirst().reduce(textAnchorRects.first ?? segmentRect) { $0.union($1) }
        let eraseUnion = eraseRects.dropFirst().reduce(eraseRects.first ?? segmentRect) { $0.union($1) }
        let target = anchorUnion.union(eraseUnion)
            .insetBy(dx: -0.8, dy: -0.6)
            .clamped(to: imageRect.insetBy(dx: edgeInset, dy: edgeInset))

        let relaxedSegmentRect = segmentRect.insetBy(dx: -1.5, dy: -1.5)
        let intersected = target.intersection(relaxedSegmentRect)
        if !intersected.isNull, intersected.width > 8, intersected.height > 8 {
            return intersected.integral
        }

        return target.integral
    }

    private func reflowTextRect(
        segmentRect: CGRect,
        eraseRects: [CGRect],
        imageRect: CGRect
    ) -> CGRect {
        let eraseUnion = eraseRects.dropFirst().reduce(eraseRects.first ?? segmentRect) { $0.union($1) }
        let lineHeight = max(segmentRect.height / 2, eraseUnion.height / 2, nativeReplaceMinimumFontSize)
        let compact = segmentRect.width <= 320 && segmentRect.height <= 120
        let horizontalPadding = compact
            ? max(min(lineHeight * 0.18, 6), 2)
            : max(min(lineHeight * 0.4, 14), 5)
        let verticalPadding = compact
            ? max(min(lineHeight * 0.12, 4), 1.5)
            : max(min(lineHeight * 0.28, 9), 3)
        return eraseUnion
            .union(segmentRect)
            .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
            .clamped(to: imageRect.insetBy(dx: edgeInset, dy: edgeInset))
            .integral
    }

    private func preferredTextAlignment(
        for segment: OverlaySegment,
        text: String
    ) -> NSTextAlignment {
        if segment.lines.count > 1 {
            return .left
        }

        switch segment.role {
        case .button:
            return .center
        case .label, .tableCell, .paragraph, .caption:
            return compactTextLength(text) <= 8 ? .center : .left
        case .title:
            return compactTextLength(text) <= 14 ? .center : .left
        case .url, .code, .number, .unknown:
            return compactTextLength(text) <= 10 ? .center : .left
        }
    }

    private func estimatedNativeReplaceFontHeight(
        for segment: OverlaySegment,
        fallbackRect: CGRect
    ) -> CGFloat {
        let heights = segment.lineBoxes.map(\.height)
        if let maxHeight = heights.max(), maxHeight > 0 {
            return maxHeight
        }
        return max(fallbackRect.height / CGFloat(max(segment.lines.count, 1)), nativeReplaceMinimumFontSize)
    }

    private func compactTextLength(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }

    private func sampledColors(
        around rect: CGRect,
        in bitmap: NSBitmapImageRep,
        imageSize: CGSize
    ) -> [NSColor] {
        let bounds = CGRect(origin: .zero, size: imageSize).insetBy(dx: edgeInset, dy: edgeInset)
        let offsets: [CGFloat] = [
            1.5,
            min(max(rect.height * 0.18, 3), 8),
            min(max(rect.height * 0.32, 5), 14)
        ]
        var points: [CGPoint] = []

        for offset in offsets {
            for ratio in stride(from: 0.12, through: 0.88, by: 0.19) {
                points.append(CGPoint(x: rect.minX + rect.width * ratio, y: rect.maxY + offset))
                points.append(CGPoint(x: rect.minX + rect.width * ratio, y: rect.minY - offset))
                points.append(CGPoint(x: rect.minX - offset, y: rect.minY + rect.height * ratio))
                points.append(CGPoint(x: rect.maxX + offset, y: rect.minY + rect.height * ratio))
            }
            points.append(CGPoint(x: rect.minX - offset, y: rect.minY - offset))
            points.append(CGPoint(x: rect.maxX + offset, y: rect.minY - offset))
            points.append(CGPoint(x: rect.minX - offset, y: rect.maxY + offset))
            points.append(CGPoint(x: rect.maxX + offset, y: rect.maxY + offset))
        }

        return points
            .filter { bounds.contains($0) }
            .compactMap { color(atDrawingPoint: $0, in: bitmap, imageSize: imageSize) }
    }

    private func color(
        atDrawingPoint point: CGPoint,
        in bitmap: NSBitmapImageRep,
        imageSize: CGSize
    ) -> NSColor? {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let normalizedX = min(max(point.x / imageSize.width, 0), 0.999_999)
        let normalizedY = min(max((imageSize.height - point.y) / imageSize.height, 0), 0.999_999)
        let pixelX = min(max(Int(normalizedX * CGFloat(bitmap.pixelsWide)), 0), max(bitmap.pixelsWide - 1, 0))
        let pixelY = min(max(Int(normalizedY * CGFloat(bitmap.pixelsHigh)), 0), max(bitmap.pixelsHigh - 1, 0))
        return bitmap.colorAt(x: pixelX, y: pixelY)
    }

    private func rgbaComponents(
        _ color: NSColor
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard let rgbColor = color.usingColorSpace(.deviceRGB) else {
            return nil
        }

        return (
            red: rgbColor.redComponent,
            green: rgbColor.greenComponent,
            blue: rgbColor.blueComponent,
            alpha: rgbColor.alphaComponent
        )
    }

    private func dominantColorComponents(
        from components: [(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)]
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        guard !components.isEmpty else {
            return (1, 1, 1, 1)
        }

        var buckets: [String: [(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)]] = [:]
        for color in components {
            let key = [
                Int((color.red * 10).rounded()),
                Int((color.green * 10).rounded()),
                Int((color.blue * 10).rounded())
            ]
            .map(String.init)
            .joined(separator: "-")
            buckets[key, default: []].append(color)
        }

        let dominantBucket = buckets.values.max { $0.count < $1.count } ?? components
        let selected = dominantBucket.count >= max(components.count / 3, 3)
            ? dominantBucket
            : trimmedAroundMedianLuminance(components)

        return (
            red: median(selected.map(\.red)),
            green: median(selected.map(\.green)),
            blue: median(selected.map(\.blue)),
            alpha: 1
        )
    }

    private func trimmedAroundMedianLuminance(
        _ components: [(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)]
    ) -> [(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)] {
        guard components.count > 4 else {
            return components
        }

        let medianLuminance = median(components.map { (0.2126 * $0.red) + (0.7152 * $0.green) + (0.0722 * $0.blue) })
        let sorted = components.sorted {
            abs(((0.2126 * $0.red) + (0.7152 * $0.green) + (0.0722 * $0.blue)) - medianLuminance) <
                abs(((0.2126 * $1.red) + (0.7152 * $1.green) + (0.0722 * $1.blue)) - medianLuminance)
        }
        return Array(sorted.prefix(max(sorted.count * 2 / 3, 3)))
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

private struct NativeReplaceRenderPlan {
    var segment: OverlaySegment
    var result: ImageOverlayTranslationResult
    var translation: String
    var segmentRect: CGRect
    var imageRect: CGRect
    var imageSize: CGSize
    var eraseRects: [CGRect]
    var lineRects: [CGRect]
    var baseTextRect: CGRect
    var eraseFills: [NativeEraseFill]
    var backgroundColor: NSColor
    var textColor: NSColor
    var complexBackground: Bool
    var reflow: Bool
}

private struct NativeEraseFill {
    var rect: CGRect
    var color: NSColor
}

private struct FittedOverlayText {
    var attributedText: NSAttributedString
    var drawRect: CGRect
    var fontSize: CGFloat
    var fitsWithinRect: Bool
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
