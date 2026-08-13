@testable import TTS
import AppKit
import CoreGraphics
import ImageIO

@MainActor
func runScreenshotAnnotationRegressionChecks() {
    checkScreenshotAnnotationUndoKeepsDocumentOrder()
    checkScreenshotAnnotationRendererPreservesPixelsAndDimensions()
    checkScreenshotAnnotationRendererDrawsAllV1Tools()
    checkScreenshotClipboardPNGPreservesLogicalSize()
    checkFrozenScreenshotCropUsesDisplayCoordinates()
    checkMovableResizableSelectionStaysWithinScreen()
}

@MainActor
private func checkFrozenScreenshotCropUsesDisplayCoordinates() {
    let screenFrame = CGRect(x: -1_000, y: 0, width: 1_000, height: 800)
    let cropRect = ScreenshotCaptureController.frozenScreenshotCropRect(
        imagePixelSize: CGSize(width: 2_000, height: 1_600),
        screenFrame: screenFrame,
        selectionRect: CGRect(x: -900, y: 100, width: 200, height: 300)
    )
    precondition(
        cropRect == CGRect(x: 200, y: 800, width: 400, height: 600),
        "frozen screenshot crop must convert AppKit display points to top-origin image pixels"
    )

    let clippedCropRect = ScreenshotCaptureController.frozenScreenshotCropRect(
        imagePixelSize: CGSize(width: 2_000, height: 1_600),
        screenFrame: screenFrame,
        selectionRect: CGRect(x: -1_050, y: 750, width: 100, height: 100)
    )
    precondition(
        clippedCropRect == CGRect(x: 0, y: 0, width: 100, height: 100),
        "frozen screenshot crop must stay inside its source display"
    )
}

@MainActor
private func checkMovableResizableSelectionStaysWithinScreen() {
    let screenFrame = CGRect(x: -1_000, y: 0, width: 1_000, height: 800)
    let selectionRect = CGRect(x: -900, y: 100, width: 200, height: 300)

    let movedRect = ScreenshotCaptureController.movedSelectionRect(
        selectionRect,
        by: CGPoint(x: -500, y: 700),
        within: screenFrame
    )
    precondition(
        movedRect == CGRect(x: -1_000, y: 500, width: 200, height: 300),
        "moving a frozen selection must preserve its size and clamp to the display"
    )

    let resizedRect = ScreenshotCaptureController.resizedSelectionRect(
        selectionRect,
        edges: [.minX, .maxY],
        by: CGPoint(x: 500, y: 1_000),
        within: screenFrame
    )
    precondition(
        resizedRect == CGRect(x: -740, y: 100, width: 40, height: 700),
        "resizing a frozen selection must honor minimum size and display bounds"
    )
}

@MainActor
private func checkScreenshotClipboardPNGPreservesLogicalSize() {
    let baseImage = makeAnnotationTestImage(width: 160, height: 120)
    guard let data = ScreenshotCaptureController.pngData(
        for: baseImage,
        logicalSize: CGSize(width: 80, height: 60)
    ),
    let source = CGImageSourceCreateWithData(data as CFData, nil),
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any],
    let horizontalDPI = properties[kCGImagePropertyDPIWidth] as? NSNumber,
    let verticalDPI = properties[kCGImagePropertyDPIHeight] as? NSNumber else {
        preconditionFailure("clipboard PNG should contain DPI metadata")
    }

    precondition(
        abs(horizontalDPI.doubleValue - 144) < 0.5,
        "Retina PNG horizontal DPI should preserve point size"
    )
    precondition(
        abs(verticalDPI.doubleValue - 144) < 0.5,
        "Retina PNG vertical DPI should preserve point size"
    )
}

@MainActor
private func checkScreenshotAnnotationUndoKeepsDocumentOrder() {
    var document = ScreenshotAnnotationDocument()
    let rectangle = ScreenshotAnnotation.rectangle(
        start: CGPoint(x: 0.1, y: 0.1),
        end: CGPoint(x: 0.8, y: 0.7)
    )
    let arrow = ScreenshotAnnotation.arrow(
        start: CGPoint(x: 0.2, y: 0.8),
        end: CGPoint(x: 0.7, y: 0.2)
    )

    document.append(rectangle)
    document.append(arrow)
    precondition(document.canUndo, "annotation document should become undoable")
    precondition(document.undo() == arrow, "undo should remove the newest annotation")
    precondition(document.annotations == [rectangle], "undo must preserve earlier annotations")
    precondition(document.undo() == rectangle, "second undo should remove the first annotation")
    precondition(!document.canUndo, "empty annotation document must not be undoable")
}

@MainActor
private func checkScreenshotAnnotationRendererPreservesPixelsAndDimensions() {
    let baseImage = makeAnnotationTestImage(width: 80, height: 60)
    guard let rendered = ScreenshotAnnotationRenderer.render(
        baseImage: baseImage,
        annotations: []
    ) else {
        preconditionFailure("renderer should return an image without annotations")
    }

    precondition(rendered.width == baseImage.width, "renderer must preserve pixel width")
    precondition(rendered.height == baseImage.height, "renderer must preserve pixel height")

    let source = NSBitmapImageRep(cgImage: baseImage)
    let output = NSBitmapImageRep(cgImage: rendered)
    let samplePoints = [
        CGPoint(x: 4, y: 4),
        CGPoint(x: 40, y: 30),
        CGPoint(x: 75, y: 55)
    ]
    for point in samplePoints {
        let sourceColor = source.colorAt(x: Int(point.x), y: Int(point.y))
        let outputColor = output.colorAt(x: Int(point.x), y: Int(point.y))
        precondition(
            colorsAreClose(sourceColor, outputColor),
            "rendering without annotations must preserve source pixels"
        )
    }
}

@MainActor
private func checkScreenshotAnnotationRendererDrawsAllV1Tools() {
    let baseImage = makeAnnotationTestImage(width: 160, height: 120)
    let annotations: [ScreenshotAnnotation] = [
        .rectangle(
            start: CGPoint(x: 0.08, y: 0.08),
            end: CGPoint(x: 0.45, y: 0.45)
        ),
        .arrow(
            start: CGPoint(x: 0.1, y: 0.85),
            end: CGPoint(x: 0.75, y: 0.55)
        ),
        .text(
            value: "TTS",
            origin: CGPoint(x: 0.52, y: 0.18),
            fontScale: 0.12
        ),
        .mosaic(
            start: CGPoint(x: 0.55, y: 0.6),
            end: CGPoint(x: 0.92, y: 0.92)
        )
    ]

    guard let rendered = ScreenshotAnnotationRenderer.render(
        baseImage: baseImage,
        annotations: annotations
    ) else {
        preconditionFailure("renderer should draw all V1 annotation tools")
    }

    precondition(rendered.width == 160, "annotated output must preserve width")
    precondition(rendered.height == 120, "annotated output must preserve height")

    let source = NSBitmapImageRep(cgImage: baseImage)
    let output = NSBitmapImageRep(cgImage: rendered)
    var changedPixelCount = 0
    for y in stride(from: 0, to: rendered.height, by: 4) {
        for x in stride(from: 0, to: rendered.width, by: 4) {
            if !colorsAreClose(source.colorAt(x: x, y: y), output.colorAt(x: x, y: y)) {
                changedPixelCount += 1
            }
        }
    }
    precondition(changedPixelCount > 20, "annotations should visibly change the rendered image")
}

private func makeAnnotationTestImage(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        preconditionFailure("could not create annotation test context")
    }

    let cellSize = 8
    for y in stride(from: 0, to: height, by: cellSize) {
        for x in stride(from: 0, to: width, by: cellSize) {
            let isLight = ((x / cellSize) + (y / cellSize)).isMultiple(of: 2)
            context.setFillColor(
                isLight
                    ? CGColor(red: 0.18, green: 0.52, blue: 0.88, alpha: 1)
                    : CGColor(red: 0.86, green: 0.72, blue: 0.22, alpha: 1)
            )
            context.fill(CGRect(
                x: x,
                y: y,
                width: min(cellSize, width - x),
                height: min(cellSize, height - y)
            ))
        }
    }

    guard let image = context.makeImage() else {
        preconditionFailure("could not create annotation test image")
    }
    return image
}

private func colorsAreClose(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
    guard
        let lhs = lhs?.usingColorSpace(.deviceRGB),
        let rhs = rhs?.usingColorSpace(.deviceRGB)
    else {
        return lhs == nil && rhs == nil
    }
    let tolerance: CGFloat = 0.02
    return abs(lhs.redComponent - rhs.redComponent) <= tolerance &&
        abs(lhs.greenComponent - rhs.greenComponent) <= tolerance &&
        abs(lhs.blueComponent - rhs.blueComponent) <= tolerance &&
        abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
}
