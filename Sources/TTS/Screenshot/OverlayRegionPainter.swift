import AppKit
import CoreGraphics
import Foundation

struct OverlayRegionPainter {
    static let edgeInset: CGFloat = 3
    static let minimumFontSize: CGFloat = 10
    static let maximumFontSize: CGFloat = 30

    static func renderLiveImage(
        originalImage: NSImage,
        regions: [OverlayDisplayRegion],
        showOCRBoxes: Bool,
        selectedSegmentID: String?
    ) -> NSImage {
        guard let cgImage = originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return originalImage
        }

        let imageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let image = NSImage(size: imageSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        let bounds = CGRect(origin: .zero, size: imageSize)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cgImage, size: imageSize).draw(in: bounds)

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        draw(
            regions: regions,
            bitmap: bitmap,
            imageSize: imageSize,
            canvasBounds: bounds,
            showOCRBoxes: showOCRBoxes,
            selectedSegmentID: selectedSegmentID
        )

        return image
    }

    static func draw(
        regions: [OverlayDisplayRegion],
        bitmap: NSBitmapImageRep,
        imageSize: CGSize,
        canvasBounds: CGRect,
        showOCRBoxes: Bool,
        selectedSegmentID: String?,
        drawTranslatedOverlays: Bool = true
    ) {
        if drawTranslatedOverlays {
            let replacementPlans = regions.compactMap {
                makeReplacementPlan(
                    region: $0,
                    bitmap: bitmap,
                    imageSize: imageSize
                )
            }

            for plan in replacementPlans {
                drawNativeReplacementBackground(
                    plan: plan,
                    imageSize: imageSize,
                    canvasBounds: canvasBounds
                )
            }

            for plan in replacementPlans {
                drawNativeReplacementText(
                    plan: plan,
                    imageSize: imageSize,
                    canvasBounds: canvasBounds
                )
            }
        }

        for region in regions {
            if showOCRBoxes || region.id == selectedSegmentID || region.phase == .translating || region.phase == .failed {
                drawStatusFrame(
                    for: region,
                    imageSize: imageSize,
                    canvasBounds: canvasBounds,
                    selected: region.id == selectedSegmentID
                )
            }
        }
    }

    static func canvasRect(
        for pixelRect: CGRect,
        imageSize: CGSize,
        canvasBounds: CGRect
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }

        let scaleX = canvasBounds.width / imageSize.width
        let scaleY = canvasBounds.height / imageSize.height
        return CGRect(
            x: canvasBounds.minX + pixelRect.minX * scaleX,
            y: canvasBounds.minY + (imageSize.height - pixelRect.minY - pixelRect.height) * scaleY,
            width: pixelRect.width * scaleX,
            height: pixelRect.height * scaleY
        )
        .integral
    }

    static func pixelPoint(
        from canvasPoint: CGPoint,
        imageSize: CGSize,
        canvasBounds: CGRect
    ) -> CGPoint {
        guard canvasBounds.width > 0, canvasBounds.height > 0 else {
            return .zero
        }

        let normalizedX = (canvasPoint.x - canvasBounds.minX) / canvasBounds.width
        let normalizedY = (canvasPoint.y - canvasBounds.minY) / canvasBounds.height
        return CGPoint(
            x: normalizedX * imageSize.width,
            y: (1 - normalizedY) * imageSize.height
        )
    }

    static func hitRegionID(
        at canvasPoint: CGPoint,
        regions: [OverlayDisplayRegion],
        imageSize: CGSize,
        canvasBounds: CGRect
    ) -> String? {
        let point = pixelPoint(from: canvasPoint, imageSize: imageSize, canvasBounds: canvasBounds)
        return regions
            .sorted { lhs, rhs in
                let lhsArea = lhs.boundingBox.width * lhs.boundingBox.height
                let rhsArea = rhs.boundingBox.width * rhs.boundingBox.height
                return lhsArea < rhsArea
            }
            .first { $0.boundingBox.insetBy(dx: -4, dy: -4).contains(point) }?
            .id
    }

    private static func makeReplacementPlan(
        region: OverlayDisplayRegion,
        bitmap: NSBitmapImageRep,
        imageSize: CGSize
    ) -> OverlayLiveReplacementPlan? {
        guard region.hasTranslatedOverlay else {
            return nil
        }

        let sourceEraseBoxes = region.segment.reflowPreferred
            ? [reflowSourceRect(for: region.segment)]
            : region.eraseBoxes
        let eraseBoxes = sourceEraseBoxes
            .map { precisionEraseRect($0, imageSize: imageSize) }
            .filter { $0.width >= 3 && $0.height >= 3 }
        guard !eraseBoxes.isEmpty else {
            return nil
        }

        let complexBackground = eraseBoxes.contains {
            isComplexBackground(around: $0, bitmap: bitmap, imageSize: imageSize)
        }

        let backgroundColor = medianBackgroundColor(
            around: eraseBoxes,
            bitmap: bitmap,
            imageSize: imageSize
        ) ?? NSColor(calibratedWhite: 0.96, alpha: 1)
        let textColor = readableTextColor(on: backgroundColor)
        let eraseFills = eraseBoxes.map {
            OverlayLiveEraseFill(
                rect: $0,
                color: medianBackgroundColor(
                    around: [$0],
                    bitmap: bitmap,
                    imageSize: imageSize
                ) ?? backgroundColor
            )
        }

        return OverlayLiveReplacementPlan(
            region: region,
            eraseBoxes: eraseBoxes,
            eraseFills: eraseFills,
            backgroundColor: backgroundColor,
            textColor: textColor,
            complexBackground: complexBackground,
            reflow: region.segment.reflowPreferred
        )
    }

    private static func drawNativeReplacementBackground(
        plan: OverlayLiveReplacementPlan,
        imageSize: CGSize,
        canvasBounds: CGRect
    ) {
        for fill in plan.eraseFills {
            drawEraseFill(
                pixelRect: fill.rect,
                fillColor: fill.color,
                complexBackground: plan.complexBackground,
                imageSize: imageSize,
                canvasBounds: canvasBounds
            )
        }
    }

    private static func drawNativeReplacementText(
        plan: OverlayLiveReplacementPlan,
        imageSize: CGSize,
        canvasBounds: CGRect
    ) {
        if plan.reflow {
            drawReflowSegmentText(
                plan.region.displayText,
                in: reflowTextRect(
                    for: plan.eraseBoxes.reduce(plan.region.boundingBox) { $0.union($1) },
                    imageSize: imageSize
                ),
                region: plan.region,
                textColor: plan.textColor,
                imageSize: imageSize,
                canvasBounds: canvasBounds
            )
            return
        }

        if drawLineAlignedText(
            region: plan.region,
            textColor: plan.textColor,
            imageSize: imageSize,
            canvasBounds: canvasBounds
        ) {
            return
        }

        drawSegmentText(
            plan.region.displayText,
            in: textRect(
                for: plan.eraseBoxes.reduce(plan.region.boundingBox) { $0.union($1) },
                padding: 2,
                imageSize: imageSize
            ),
            role: plan.region.segment.role,
            textColor: plan.textColor,
            imageSize: imageSize,
            canvasBounds: canvasBounds
        )
    }

    private static func drawLineAlignedText(
        region: OverlayDisplayRegion,
        textColor: NSColor,
        imageSize: CGSize,
        canvasBounds: CGRect
    ) -> Bool {
        guard !region.lineTranslations.isEmpty,
              region.lineTranslations.count == region.lineBoxes.count else {
            return false
        }

        let sortedTranslations = region.lineTranslations.sorted { $0.lineIndex < $1.lineIndex }
        var layouts: [(NSAttributedString, CGRect)] = []
        layouts.reserveCapacity(sortedTranslations.count)

        for item in sortedTranslations {
            guard region.lineBoxes.indices.contains(item.lineIndex) else {
                return false
            }

            let pixelTextRect = textRect(
                for: region.lineBoxes[item.lineIndex],
                padding: max(min(region.lineBoxes[item.lineIndex].height * 0.16, 5), 1.5),
                imageSize: imageSize
            )
            let canvasTextRect = canvasRect(for: pixelTextRect, imageSize: imageSize, canvasBounds: canvasBounds)
            guard canvasTextRect.width > 6, canvasTextRect.height > 6 else {
                return false
            }

            let layout = fittedText(
                item.translation,
                in: canvasTextRect,
                role: region.segment.role,
                textColor: textColor,
                sourcePixelHeight: region.lineBoxes[item.lineIndex].height,
                lineCount: 1
            )
            guard layout.fits else {
                return false
            }
            layouts.append((layout.text, layout.rect))
        }

        for layout in layouts {
            layout.0.draw(in: layout.1)
        }
        return true
    }

    private static func drawSegmentText(
        _ text: String,
        in pixelRect: CGRect,
        role: OverlaySegmentRole,
        textColor: NSColor,
        imageSize: CGSize,
        canvasBounds: CGRect
    ) {
        let canvasTextRect = canvasRect(for: pixelRect, imageSize: imageSize, canvasBounds: canvasBounds)
        guard canvasTextRect.width > 8, canvasTextRect.height > 8 else {
            return
        }

        let layout = fittedText(
            text,
            in: canvasTextRect,
            role: role,
            textColor: textColor,
            sourcePixelHeight: pixelRect.height,
            lineCount: max(Int(round(pixelRect.height / 18)), 1)
        )
        layout.text.draw(in: layout.rect)
    }

    private static func drawReflowSegmentText(
        _ text: String,
        in pixelRect: CGRect,
        region: OverlayDisplayRegion,
        textColor: NSColor,
        imageSize: CGSize,
        canvasBounds: CGRect
    ) {
        let canvasTextRect = canvasRect(for: pixelRect, imageSize: imageSize, canvasBounds: canvasBounds)
        guard canvasTextRect.width > 8, canvasTextRect.height > 8 else {
            return
        }

        let sourceLineHeight = max(
            region.lineBoxes.map(\.height).max() ?? region.boundingBox.height,
            minimumFontSize
        )
        let layout = fittedText(
            text,
            in: canvasTextRect,
            role: region.segment.role,
            textColor: textColor,
            sourcePixelHeight: sourceLineHeight,
            lineCount: max(region.lineBoxes.count, 1)
        )
        layout.text.draw(in: layout.rect)
    }

    private static func drawEraseFill(
        pixelRect: CGRect,
        fillColor: NSColor,
        complexBackground: Bool,
        imageSize: CGSize,
        canvasBounds: CGRect
    ) {
        let rect = canvasRect(for: pixelRect, imageSize: imageSize, canvasBounds: canvasBounds)
        guard rect.width > 1, rect.height > 1 else {
            return
        }

        let color = fillColor.withAlphaComponent(1)
        color.setFill()
        let radius = min(rect.height * 0.04, 1.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.fill()

        if complexBackground {
            (color.blended(withFraction: 0.12, of: .white) ?? color).setStroke()
            path.lineWidth = 0.35
            path.stroke()
        }
    }

    private static func drawStatusFrame(
        for region: OverlayDisplayRegion,
        imageSize: CGSize,
        canvasBounds: CGRect,
        selected: Bool
    ) {
        let rect = canvasRect(for: region.boundingBox, imageSize: imageSize, canvasBounds: canvasBounds)
            .insetBy(dx: -2, dy: -2)
        guard rect.width > 4, rect.height > 4 else {
            return
        }

        let color: NSColor
        switch region.phase {
        case .recognized:
            color = .systemBlue
        case .translating:
            color = .systemPurple
        case .translated:
            color = .systemGreen
        case .fallbackUsed:
            color = .systemTeal
        case .originalKept:
            color = .systemGray
        case .failed:
            color = .systemRed
        case .excluded:
            color = .systemOrange
        }

        color.withAlphaComponent(selected ? 0.22 : 0.1).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        if selected || region.phase == .translating || region.phase == .failed || region.phase == .excluded {
            path.fill()
        }
        color.withAlphaComponent(selected ? 0.95 : 0.64).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()
    }

    private static func fittedText(
        _ text: String,
        in rect: CGRect,
        role: OverlaySegmentRole,
        textColor: NSColor,
        sourcePixelHeight: CGFloat,
        lineCount: Int
    ) -> (text: NSAttributedString, rect: CGRect, fits: Bool) {
        let cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSize = min(maximumFontSize, max(minimumFontSize, sourcePixelHeight * 0.82))
        let alignment: NSTextAlignment = {
            switch role {
            case .button:
                return .center
            case .title:
                return compactLength(cleaned) <= 14 ? .center : .left
            case .label, .tableCell:
                return compactLength(cleaned) <= 10 ? .center : .left
            case .paragraph, .caption, .code, .url, .number, .unknown:
                return lineCount <= 1 && compactLength(cleaned) <= 10 ? .center : .left
            }
        }()

        var selectedFont = NSFont.systemFont(ofSize: baseSize, weight: .semibold)
        var measured = CGRect(origin: .zero, size: rect.size)
        var fits = false

        for size in stride(from: baseSize, through: minimumFontSize, by: -0.5) {
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            let attributed = attributedText(
                cleaned,
                font: font,
                alignment: alignment,
                textColor: textColor
            )
            let candidate = attributed.boundingRect(
                with: rect.size,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            .integral
            selectedFont = font
            measured = candidate
            if candidate.width <= rect.width && candidate.height <= rect.height {
                fits = true
                break
            }
        }

        let finalText = attributedText(
            cleaned,
            font: selectedFont,
            alignment: alignment,
            textColor: textColor
        )
        let finalMeasured = finalText.boundingRect(
            with: rect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        .integral
        let resolvedMeasured = finalMeasured.isEmpty ? measured : finalMeasured
        let width = min(rect.width, max(resolvedMeasured.width, alignment == .center ? rect.width * 0.7 : resolvedMeasured.width))
        let height = min(rect.height, resolvedMeasured.height)
        let x: CGFloat = alignment == .center
            ? rect.minX + max((rect.width - width) / 2, 0)
            : rect.minX
        let y = rect.minY + max((rect.height - height) / 2, 0)

        return (
            finalText,
            CGRect(x: x, y: y, width: width, height: height).integral,
            fits
        )
    }

    private static func attributedText(
        _ text: String,
        font: NSFont,
        alignment: NSTextAlignment,
        textColor: NSColor
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = containsCJK(text) ? .byCharWrapping : .byWordWrapping
        paragraphStyle.lineSpacing = max(1, font.pointSize * 0.1)

        let shadow = NSShadow()
        let components = rgbaComponents(textColor)
        let isLightText = (components?.red ?? 0) > 0.7
        shadow.shadowColor = isLightText
            ? NSColor.black.withAlphaComponent(0.22)
            : NSColor.white.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 0.7
        shadow.shadowOffset = .zero

        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle,
                .shadow: shadow
            ]
        )
    }

    private static func textRect(
        for pixelRect: CGRect,
        padding: CGFloat,
        imageSize: CGSize
    ) -> CGRect {
        expandAndClamp(pixelRect, padding: padding, imageSize: imageSize)
    }

    private static func precisionEraseRect(
        _ rect: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        let horizontalPadding = min(max(rect.height * 0.08, 1), 3)
        let verticalPadding = min(max(rect.height * 0.06, 0.75), 2)
        return rect
            .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
            .intersection(CGRect(origin: .zero, size: imageSize).insetBy(dx: edgeInset, dy: edgeInset))
            .integral
    }

    private static func reflowSourceRect(for segment: OverlaySegment) -> CGRect {
        let box = segment.boundingBox.standardized
        let height = max(box.height, segment.lineBoxes.map(\.height).max() ?? box.height)
        let compact = compactLength(segment.sourceText) <= 24
        let horizontalPadding = compact
            ? max(min(height * 0.18, 8), 2)
            : max(min(height * 0.35, 16), 5)
        let verticalPadding = compact
            ? max(min(height * 0.12, 5), 1.5)
            : max(min(height * 0.22, 10), 3)
        return box.insetBy(dx: -horizontalPadding, dy: -verticalPadding).standardized
    }

    private static func reflowTextRect(
        for pixelRect: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        let lineHeight = max(pixelRect.height / 2, minimumFontSize)
        let compact = pixelRect.width <= 320 && pixelRect.height <= 120
        return pixelRect
            .insetBy(
                dx: -(compact ? max(min(lineHeight * 0.16, 6), 2) : max(min(lineHeight * 0.32, 12), 4)),
                dy: -(compact ? max(min(lineHeight * 0.10, 4), 1.5) : max(min(lineHeight * 0.24, 8), 3))
            )
            .intersection(CGRect(origin: .zero, size: imageSize).insetBy(dx: edgeInset, dy: edgeInset))
            .integral
    }

    private static func expandAndClamp(
        _ rect: CGRect,
        padding: CGFloat,
        imageSize: CGSize
    ) -> CGRect {
        rect
            .insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(origin: .zero, size: imageSize).insetBy(dx: edgeInset, dy: edgeInset))
            .integral
    }

    private static func medianBackgroundColor(
        around rects: [CGRect],
        bitmap: NSBitmapImageRep,
        imageSize: CGSize
    ) -> NSColor? {
        let colors = rects.flatMap { sampledColors(around: $0, bitmap: bitmap, imageSize: imageSize) }
        let components = colors.compactMap(rgbaComponents)
        guard !components.isEmpty else {
            return nil
        }

        let dominant = dominantColorComponents(from: components)

        return NSColor(
            calibratedRed: dominant.red,
            green: dominant.green,
            blue: dominant.blue,
            alpha: 1
        )
    }

    private static func isComplexBackground(
        around rect: CGRect,
        bitmap: NSBitmapImageRep,
        imageSize: CGSize
    ) -> Bool {
        let components = sampledColors(around: rect, bitmap: bitmap, imageSize: imageSize)
            .compactMap(rgbaComponents)
        guard components.count >= 4 else {
            return true
        }

        let averageLuminance = components
            .map { luminance(red: $0.red, green: $0.green, blue: $0.blue) }
            .reduce(0, +) / CGFloat(components.count)
        let spread = components
            .map { abs(luminance(red: $0.red, green: $0.green, blue: $0.blue) - averageLuminance) }
            .reduce(0, +) / CGFloat(components.count)
        return spread > 0.12
    }

    private static func sampledColors(
        around rect: CGRect,
        bitmap: NSBitmapImageRep,
        imageSize: CGSize
    ) -> [NSColor] {
        let offsets: [CGFloat] = [
            1.5,
            min(max(rect.height * 0.18, 3), 8),
            min(max(rect.height * 0.32, 5), 14)
        ]
        var points: [CGPoint] = []
        for offset in offsets {
            for ratio in stride(from: 0.12, through: 0.88, by: 0.19) {
                points.append(CGPoint(x: rect.minX + rect.width * ratio, y: rect.minY - offset))
                points.append(CGPoint(x: rect.minX + rect.width * ratio, y: rect.maxY + offset))
                points.append(CGPoint(x: rect.minX - offset, y: rect.minY + rect.height * ratio))
                points.append(CGPoint(x: rect.maxX + offset, y: rect.minY + rect.height * ratio))
            }
            points.append(CGPoint(x: rect.minX - offset, y: rect.minY - offset))
            points.append(CGPoint(x: rect.maxX + offset, y: rect.minY - offset))
            points.append(CGPoint(x: rect.minX - offset, y: rect.maxY + offset))
            points.append(CGPoint(x: rect.maxX + offset, y: rect.maxY + offset))
        }

        return points
            .filter { CGRect(origin: .zero, size: imageSize).contains($0) }
            .compactMap { color(atTopLeftPixelPoint: $0, bitmap: bitmap, imageSize: imageSize) }
    }

    private static func color(
        atTopLeftPixelPoint point: CGPoint,
        bitmap: NSBitmapImageRep,
        imageSize: CGSize
    ) -> NSColor? {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let x = min(max(Int(round(point.x / imageSize.width * CGFloat(bitmap.pixelsWide))), 0), max(bitmap.pixelsWide - 1, 0))
        let y = min(max(Int(round(point.y / imageSize.height * CGFloat(bitmap.pixelsHigh))), 0), max(bitmap.pixelsHigh - 1, 0))
        return bitmap.colorAt(x: x, y: y)
    }

    private static func readableTextColor(on background: NSColor) -> NSColor {
        guard let components = rgbaComponents(background) else {
            return NSColor(calibratedWhite: 0.08, alpha: 0.98)
        }

        return luminance(red: components.red, green: components.green, blue: components.blue) < 0.56
            ? NSColor(calibratedWhite: 0.98, alpha: 0.98)
            : NSColor(calibratedWhite: 0.08, alpha: 0.98)
    }

    private static func luminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    private static func rgbaComponents(
        _ color: NSColor
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return nil
        }
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
    }

    private static func dominantColorComponents(
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

    private static func trimmedAroundMedianLuminance(
        _ components: [(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)]
    ) -> [(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)] {
        guard components.count > 4 else {
            return components
        }

        let medianLuminance = median(components.map { luminance(red: $0.red, green: $0.green, blue: $0.blue) })
        let sorted = components.sorted {
            abs(luminance(red: $0.red, green: $0.green, blue: $0.blue) - medianLuminance) <
                abs(luminance(red: $1.red, green: $1.green, blue: $1.blue) - medianLuminance)
        }
        return Array(sorted.prefix(max(sorted.count * 2 / 3, 3)))
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
                (0x3400...0x4DBF).contains(Int(scalar.value))
        }
    }

    private static func compactLength(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }
}

private struct OverlayLiveReplacementPlan {
    var region: OverlayDisplayRegion
    var eraseBoxes: [CGRect]
    var eraseFills: [OverlayLiveEraseFill]
    var backgroundColor: NSColor
    var textColor: NSColor
    var complexBackground: Bool
    var reflow: Bool
}

private struct OverlayLiveEraseFill {
    var rect: CGRect
    var color: NSColor
}
