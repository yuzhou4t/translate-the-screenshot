@testable import TTS
import AppKit
import Foundation

func checkScreenshotTranslationRendererPreservesButtonSurface() {
    let imageSize = CGSize(width: 420, height: 220)
    let originalImage = makeButtonFixtureImage(size: imageSize)
    let eraseBox = CGRect(x: 46, y: 98, width: 328, height: 88)
    let segment = OverlaySegment(
        id: "button",
        sourceBlockIDs: [],
        sourceAtomIDs: [],
        sourceText: "Translate Screenshot",
        lines: [],
        boundingBox: eraseBox,
        lineBoxes: [eraseBox],
        eraseBoxes: [eraseBox],
        role: .button,
        readingOrder: 0,
        shouldTranslate: true
    )
    let result = ImageOverlayTranslationResult(
        segmentID: segment.id,
        sourceText: segment.sourceText,
        translatedText: "翻译截图",
        lineTranslations: [],
        status: .success,
        errorMessage: nil
    )

    let exportedImage = try! ScreenshotTranslationOverlayRenderer().render(
        originalImage: originalImage,
        segments: [segment],
        translationResults: [result],
        style: .nativeReplace
    )
    let liveImage = OverlayRegionPainter.renderLiveImage(
        originalImage: originalImage,
        regions: [
            OverlayDisplayRegion(
                segment: segment,
                phase: .translated,
                translatedText: result.translatedText,
                lineTranslations: [],
                errorMessage: nil,
                isExcluded: false
            )
        ],
        showOCRBoxes: false,
        selectedSegmentID: nil
    )

    writePNG(exportedImage, to: "/private/tmp/tts-renderer-regression-export.png")
    writePNG(liveImage, to: "/private/tmp/tts-renderer-regression-live.png")

    let originalPixelSize = cgPixelSize(of: originalImage)
    for (label, image) in [("export", exportedImage), ("live", liveImage)] {
        precondition(
            cgPixelSize(of: image) == originalPixelSize,
            "\(label) renderer must preserve the source pixel dimensions"
        )
        precondition(
            cgColorSpaceName(of: image) == cgColorSpaceName(of: originalImage),
            "\(label) renderer must preserve the source color space"
        )
        let renderedSurface = pixelColor(in: image, topLeftPoint: CGPoint(x: 54, y: 140))
        let untouchedButtonSurface = pixelColor(
            in: image,
            topLeftPoint: CGPoint(x: 43, y: 140)
        )
        FileHandle.standardError.write(
            Data(
                "\(label) surface untouched=\(untouchedButtonSurface) filled=\(renderedSurface)\n".utf8
            )
        )
        precondition(
            colorDistance(untouchedButtonSurface, renderedSurface) < 0.10,
            "\(label) renderer must keep the compact button surface color"
        )
        precondition(
            colorDistance(
                pixelColor(in: originalImage, topLeftPoint: CGPoint(x: 43, y: 140)),
                untouchedButtonSurface
            ) < 0.02,
            "\(label) renderer must keep untouched source pixels colorimetrically stable"
        )
        precondition(
            countNearWhitePixels(in: image, topLeftRect: CGRect(x: 90, y: 108, width: 240, height: 66)) > 12,
            "\(label) renderer must choose readable light text on the blue button"
        )
        precondition(
            countDifferentPixels(
                lhs: originalImage,
                rhs: image,
                topLeftRect: CGRect(x: 90, y: 108, width: 240, height: 66)
            ) > 20,
            "\(label) renderer must write the translated text into the output bitmap"
        )
    }
}

private func makeButtonFixtureImage(size: CGSize) -> NSImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    let context = CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
    context.fill(CGRect(origin: .zero, size: size))
    let buttonRect = CGRect(x: 40, y: 24, width: 340, height: 104)
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.12, 0.36, 0.92, 1])!)
    context.fill(buttonRect)
    return NSImage(cgImage: context.makeImage()!, size: size)
}

private func cgPixelSize(of image: NSImage) -> CGSize {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return .zero
    }
    return CGSize(width: cgImage.width, height: cgImage.height)
}

private func cgColorSpaceName(of image: NSImage) -> String? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let name = cgImage.colorSpace?.name else {
        return nil
    }
    return name as String
}

private func pixelColor(
    in image: NSImage,
    topLeftPoint: CGPoint
) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        preconditionFailure("expected a CGImage-backed regression image")
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    let x = min(
        max(Int(topLeftPoint.x / image.size.width * CGFloat(bitmap.pixelsWide)), 0),
        bitmap.pixelsWide - 1
    )
    let y = min(
        max(Int(topLeftPoint.y / image.size.height * CGFloat(bitmap.pixelsHigh)), 0),
        bitmap.pixelsHigh - 1
    )
    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
        preconditionFailure("expected a readable RGB pixel")
    }
    return (color.redComponent, color.greenComponent, color.blueComponent)
}

private func colorDistance(
    _ lhs: (red: CGFloat, green: CGFloat, blue: CGFloat),
    _ rhs: (red: CGFloat, green: CGFloat, blue: CGFloat)
) -> CGFloat {
    abs(lhs.red - rhs.red) + abs(lhs.green - rhs.green) + abs(lhs.blue - rhs.blue)
}

private func countNearWhitePixels(
    in image: NSImage,
    topLeftRect: CGRect
) -> Int {
    var count = 0

    for y in Int(topLeftRect.minY)..<Int(topLeftRect.maxY) {
        for x in Int(topLeftRect.minX)..<Int(topLeftRect.maxX) {
            let color = pixelColor(
                in: image,
                topLeftPoint: CGPoint(x: CGFloat(x), y: CGFloat(y))
            )
            if color.red > 0.78,
               color.green > 0.78,
               color.blue > 0.78 {
                count += 1
            }
        }
    }
    return count
}

private func countDifferentPixels(
    lhs: NSImage,
    rhs: NSImage,
    topLeftRect: CGRect
) -> Int {
    var count = 0
    for y in Int(topLeftRect.minY)..<Int(topLeftRect.maxY) {
        for x in Int(topLeftRect.minX)..<Int(topLeftRect.maxX) {
            let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
            if colorDistance(
                pixelColor(in: lhs, topLeftPoint: point),
                pixelColor(in: rhs, topLeftPoint: point)
            ) > 0.10 {
                count += 1
            }
        }
    }
    return count
}

private func writePNG(
    _ image: NSImage,
    to path: String
) {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = NSBitmapImageRep(cgImage: cgImage).representation(
            using: .png,
            properties: [:]
          ) else {
        preconditionFailure("failed to encode renderer regression image")
    }
    try! data.write(to: URL(fileURLWithPath: path), options: .atomic)
}
