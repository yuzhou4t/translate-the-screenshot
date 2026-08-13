import AppKit
import CoreGraphics

enum ScreenshotAnnotationTool: CaseIterable, Hashable {
    case move
    case rectangle
    case arrow
    case text
    case mosaic
}

struct ScreenshotSelectionResizeEdges: OptionSet, Hashable {
    let rawValue: Int

    static let minX = Self(rawValue: 1 << 0)
    static let maxX = Self(rawValue: 1 << 1)
    static let minY = Self(rawValue: 1 << 2)
    static let maxY = Self(rawValue: 1 << 3)
}

enum ScreenshotAnnotation: Equatable {
    case rectangle(start: CGPoint, end: CGPoint)
    case arrow(start: CGPoint, end: CGPoint)
    case text(value: String, origin: CGPoint, fontScale: CGFloat)
    case mosaic(start: CGPoint, end: CGPoint)
}

struct ScreenshotAnnotationDocument: Equatable {
    private(set) var annotations: [ScreenshotAnnotation] = []

    var canUndo: Bool {
        !annotations.isEmpty
    }

    mutating func append(_ annotation: ScreenshotAnnotation) {
        annotations.append(annotation)
    }

    @discardableResult
    mutating func undo() -> ScreenshotAnnotation? {
        annotations.popLast()
    }
}

@MainActor
struct ScreenshotAnnotationRenderer {
    private static let annotationColor = NSColor.systemRed

    static func render(
        baseImage: CGImage,
        annotations: [ScreenshotAnnotation],
        logicalSize: CGSize? = nil
    ) -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: width,
                  pixelsHigh: height,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        let canvasSize = CGSize(width: width, height: height)
        let displaySize = validLogicalSize(logicalSize) ?? canvasSize
        let pixelScale = max(
            canvasSize.width / displaySize.width,
            canvasSize.height / displaySize.height
        )
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let sourceImage = NSImage(cgImage: baseImage, size: canvasSize)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high
        sourceImage.draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )

        for annotation in annotations {
            guard case let .mosaic(start, end) = annotation else {
                continue
            }
            drawMosaic(
                sourceImage: sourceImage,
                in: imageRect(start: start, end: end, canvasSize: canvasSize),
                graphicsContext: graphicsContext,
                blockSize: 12 * pixelScale
            )
        }

        for annotation in annotations {
            switch annotation {
            case let .rectangle(start, end):
                drawRectangle(
                    imageRect(start: start, end: end, canvasSize: canvasSize),
                    canvasSize: canvasSize
                )
            case let .arrow(start, end):
                drawArrow(
                    from: imagePoint(start, canvasSize: canvasSize),
                    to: imagePoint(end, canvasSize: canvasSize),
                    canvasSize: canvasSize
                )
            case let .text(value, origin, fontScale):
                drawText(
                    value,
                    at: imagePoint(origin, canvasSize: canvasSize),
                    fontScale: fontScale,
                    bounds: bounds
                )
            case .mosaic:
                break
            }
        }

        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }

    private static func drawRectangle(_ rect: CGRect, canvasSize: CGSize) {
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        let path = NSBezierPath(rect: rect)
        path.lineWidth = strokeWidth(canvasSize: canvasSize)
        annotationColor.setStroke()
        path.stroke()
    }

    private static func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        canvasSize: CGSize
    ) {
        let lineWidth = strokeWidth(canvasSize: canvasSize)
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        annotationColor.setStroke()
        path.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(lineWidth * 4.5, 12)
        let wingAngle = CGFloat.pi / 7
        let firstWing = CGPoint(
            x: end.x - headLength * cos(angle - wingAngle),
            y: end.y - headLength * sin(angle - wingAngle)
        )
        let secondWing = CGPoint(
            x: end.x - headLength * cos(angle + wingAngle),
            y: end.y - headLength * sin(angle + wingAngle)
        )

        let head = NSBezierPath()
        head.move(to: firstWing)
        head.line(to: end)
        head.line(to: secondWing)
        head.lineWidth = lineWidth
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.stroke()
    }

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        fontScale: CGFloat,
        bounds: CGRect
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let fontSize = min(max(fontScale * bounds.height, 12), 96)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attributedText = NSAttributedString(string: trimmed, attributes: attributes)
        let textSize = attributedText.size()
        let padding = max(4, fontSize * 0.22)
        let backgroundSize = CGSize(
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        let origin = CGPoint(
            x: min(max(point.x, bounds.minX), max(bounds.minX, bounds.maxX - backgroundSize.width)),
            y: min(
                max(point.y - backgroundSize.height, bounds.minY),
                max(bounds.minY, bounds.maxY - backgroundSize.height)
            )
        )
        let backgroundRect = CGRect(origin: origin, size: backgroundSize)

        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(
            roundedRect: backgroundRect,
            xRadius: padding,
            yRadius: padding
        ).fill()
        attributedText.draw(
            at: CGPoint(x: origin.x + padding, y: origin.y + padding)
        )
    }

    private static func drawMosaic(
        sourceImage: NSImage,
        in rect: CGRect,
        graphicsContext: NSGraphicsContext,
        blockSize: CGFloat
    ) {
        guard rect.width >= 1, rect.height >= 1 else {
            return
        }

        let sampleWidth = max(1, Int(ceil(rect.width / blockSize)))
        let sampleHeight = max(1, Int(ceil(rect.height / blockSize)))
        guard let sampleBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: sampleWidth,
            pixelsHigh: sampleHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let sampleContext = NSGraphicsContext(bitmapImageRep: sampleBitmap) else {
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = sampleContext
        sampleContext.imageInterpolation = .low
        sourceImage.draw(
            in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight),
            from: rect,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
        sampleContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let sampleCGImage = sampleBitmap.cgImage else {
            return
        }
        let sampleImage = NSImage(
            cgImage: sampleCGImage,
            size: CGSize(width: sampleWidth, height: sampleHeight)
        )
        let previousInterpolation = graphicsContext.imageInterpolation
        graphicsContext.imageInterpolation = .none
        sampleImage.draw(
            in: rect,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
        graphicsContext.imageInterpolation = previousInterpolation
    }

    private static func validLogicalSize(_ size: CGSize?) -> CGSize? {
        guard let size,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return size
    }

    private static func imagePoint(
        _ normalizedPoint: CGPoint,
        canvasSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: normalizedPoint.x.clamped(to: 0 ... 1) * canvasSize.width,
            y: (1 - normalizedPoint.y.clamped(to: 0 ... 1)) * canvasSize.height
        )
    }

    private static func imageRect(
        start: CGPoint,
        end: CGPoint,
        canvasSize: CGSize
    ) -> CGRect {
        let first = imagePoint(start, canvasSize: canvasSize)
        let second = imagePoint(end, canvasSize: canvasSize)
        return CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(first.x - second.x),
            height: abs(first.y - second.y)
        )
    }

    private static func strokeWidth(canvasSize: CGSize) -> CGFloat {
        min(max(min(canvasSize.width, canvasSize.height) * 0.006, 2), 12)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
