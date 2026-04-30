import AppKit
import CoreGraphics
import Foundation

struct OverlayPipelineDebugWriter: Sendable {
    var isEnabled: Bool {
        let environmentValue = ProcessInfo.processInfo.environment["TTS_DEBUG_OVERLAY_PIPELINE"] ?? ""
        if ["1", "true", "yes"].contains(environmentValue.lowercased()) {
            return true
        }

        return UserDefaults.standard.bool(forKey: "debugOverlayPipeline")
    }

    func writeArtifacts(
        originalImage: NSImage,
        ocrSnapshot: OverlayOCRSnapshot,
        segmentation: OverlaySegmentationSnapshot,
        translationResults: [ImageOverlayTranslationResult],
        renderer: ScreenshotTranslationOverlayRenderer,
        overlayStyle: ScreenshotTranslationOverlayStyle = .nativeReplace
    ) {
        guard isEnabled else {
            return
        }

        do {
            let directory = try makeDebugDirectory()
            let pixelOriginal = pixelSizedImage(originalImage) ?? originalImage
            let pixelOCRInput = pixelSizedImage(ocrSnapshot.ocrInputImage) ?? ocrSnapshot.ocrInputImage

            try writePNG(pixelOriginal, to: directory.appendingPathComponent("original.png"))
            try writePNG(pixelOCRInput, to: directory.appendingPathComponent("ocr_input.png"))
            try writePNG(drawOCRBoxes(on: pixelOCRInput, boxDebugInfo: ocrSnapshot.boxDebugInfo), to: directory.appendingPathComponent("ocr_boxes.png"))
            try writePNG(drawMappedBoxes(on: pixelOriginal, boxDebugInfo: ocrSnapshot.boxDebugInfo), to: directory.appendingPathComponent("mapped_boxes.png"))
            try writePNG(drawTextAtoms(on: pixelOriginal, atoms: ocrSnapshot.textAtoms), to: directory.appendingPathComponent("text_atoms.png"))
            try writePNG(drawTextLines(on: pixelOriginal, lines: segmentation.textLines), to: directory.appendingPathComponent("text_lines.png"))
            try writePNG(drawSegments(on: pixelOriginal, segments: segmentation.overlaySegments), to: directory.appendingPathComponent("overlay_segments.png"))
            try writePNG(drawEraseBoxes(on: pixelOriginal, segments: segmentation.overlaySegments), to: directory.appendingPathComponent("erase_boxes.png"))
            try writePNG(renderEraseOnly(on: pixelOriginal, segments: segmentation.overlaySegments), to: directory.appendingPathComponent("erase_only.png"))
            let finalOverlay = try renderer.render(
                originalImage: pixelOriginal,
                segments: segmentation.overlaySegments,
                translationResults: translationResults,
                style: overlayStyle
            )
            try writePNG(finalOverlay, to: directory.appendingPathComponent("final_overlay.png"))

            let report = buildReport(
                ocrSnapshot: ocrSnapshot,
                segmentation: segmentation,
                overlayStyle: overlayStyle
            )
            let reportData = try JSONEncoder.prettyPrinted.encode(report)
            try reportData.write(to: directory.appendingPathComponent("debug_report.json"))
            print("overlay debug artifacts saved: \(directory.path)")
        } catch {
            print("overlay debug artifacts failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func writeSessionArtifacts(
        originalImage: NSImage,
        ocrSnapshot: OverlayOCRSnapshot,
        segmentation: OverlaySegmentationSnapshot,
        displayRegions: [OverlayDisplayRegion],
        translationResults: [ImageOverlayTranslationResult],
        renderer: ScreenshotTranslationOverlayRenderer,
        force: Bool = false
    ) -> URL? {
        guard force || isEnabled else {
            return nil
        }

        do {
            let directory = try makeDebugDirectory()
            let pixelOriginal = pixelSizedImage(originalImage) ?? originalImage
            try writePNG(pixelOriginal, to: directory.appendingPathComponent("original.png"))

            let pixelOCRInput = pixelSizedImage(ocrSnapshot.ocrInputImage) ?? ocrSnapshot.ocrInputImage
            try writePNG(pixelOCRInput, to: directory.appendingPathComponent("ocr_input.png"))
            try writePNG(
                drawOCRBoxes(on: pixelOCRInput, boxDebugInfo: ocrSnapshot.boxDebugInfo),
                to: directory.appendingPathComponent("ocr_boxes.png")
            )
            if let layoutSnapshot = ocrSnapshot.layoutSnapshot {
                try writePNG(drawLayoutBands(on: pixelOriginal, bands: layoutSnapshot.bands), to: directory.appendingPathComponent("layout_bands.png"))
                try writePNG(drawLayoutSections(on: pixelOriginal, bands: layoutSnapshot.bands), to: directory.appendingPathComponent("layout_sections.png"))
                try writePNG(drawMergeDecisions(on: pixelOriginal, decisions: layoutSnapshot.mergeDecisions, lines: segmentation.textLines), to: directory.appendingPathComponent("merge_decisions.png"))
            }

            try writePNG(drawTextLines(on: pixelOriginal, lines: segmentation.textLines), to: directory.appendingPathComponent("text_lines.png"))
            try writePNG(drawSegments(on: pixelOriginal, segments: segmentation.overlaySegments), to: directory.appendingPathComponent("overlay_segments.png"))
            try writePNG(drawReflowBlocks(on: pixelOriginal, segments: segmentation.overlaySegments), to: directory.appendingPathComponent("reflow_blocks.png"))
            try writePNG(drawDisplayRegions(on: pixelOriginal, regions: displayRegions), to: directory.appendingPathComponent("display_regions.png"))
            try writePNG(renderErasePreview(on: pixelOriginal, regions: displayRegions), to: directory.appendingPathComponent("erase_preview.png"))

            let liveImage = OverlayRegionPainter.renderLiveImage(
                originalImage: pixelOriginal,
                regions: displayRegions,
                showOCRBoxes: false,
                selectedSegmentID: nil
            )
            try writePNG(liveImage, to: directory.appendingPathComponent("translated_live.png"))

            let resultByID = Dictionary(uniqueKeysWithValues: translationResults.map { ($0.segmentID, $0) })
            let translatedPairs = segmentation.overlaySegments.compactMap { segment -> (OverlaySegment, ImageOverlayTranslationResult)? in
                guard let result = resultByID[segment.id],
                      result.status == .success || result.status == .fallbackUsed,
                      result.translatedText.trimmingCharacters(in: .whitespacesAndNewlines) != segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return nil
                }
                return (segment, result)
            }

            let finalOverlay: NSImage
            if translatedPairs.isEmpty {
                finalOverlay = pixelOriginal
            } else {
                finalOverlay = try renderer.render(
                    originalImage: pixelOriginal,
                    segments: translatedPairs.map(\.0),
                    translationResults: translatedPairs.map(\.1),
                    style: .nativeReplace
                )
            }
            try writePNG(finalOverlay, to: directory.appendingPathComponent("final_overlay.png"))

            let report = buildReport(
                ocrSnapshot: ocrSnapshot,
                segmentation: segmentation,
                overlayStyle: .nativeReplace
            )
            let reportData = try JSONEncoder.prettyPrinted.encode(report)
            try reportData.write(to: directory.appendingPathComponent("debug_report.json"))
            print("overlay debug artifacts saved: \(directory.path)")
            return directory
        } catch {
            print("overlay debug artifacts failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func pixelSizedImage(_ image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        )
    }

    private func makeDebugDirectory() throws -> URL {
        let timestamp = DateFormatter.overlayDebugTimestamp.string(from: Date())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-overlay-debug", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func drawTextAtoms(on image: NSImage, atoms: [TextAtom]) -> NSImage {
        annotate(on: image) {
            for atom in atoms {
                let rect = drawingRect(atom.boundingBox, imageSize: image.size)
                NSColor.systemGreen.withAlphaComponent(0.18).setFill()
                NSBezierPath(rect: rect).fill()
                NSColor.systemGreen.setStroke()
                NSBezierPath(rect: rect).stroke()
            }
        }
    }

    private func drawOCRBoxes(on image: NSImage, boxDebugInfo: [OCRTextBoxDebugInfo]) -> NSImage {
        annotate(on: image) {
            for box in boxDebugInfo {
                let rect = drawingRect(box.ocrPixelRect, imageSize: image.size)
                NSColor.systemPurple.withAlphaComponent(0.12).setFill()
                NSBezierPath(rect: rect).fill()
                NSColor.systemPurple.setStroke()
                NSBezierPath(rect: rect).stroke()
            }
        }
    }

    private func drawMappedBoxes(on image: NSImage, boxDebugInfo: [OCRTextBoxDebugInfo]) -> NSImage {
        annotate(on: image) {
            for box in boxDebugInfo {
                let rect = drawingRect(box.mappedPixelRect, imageSize: image.size)
                NSColor.systemYellow.withAlphaComponent(0.16).setFill()
                NSBezierPath(rect: rect).fill()
                NSColor.systemYellow.setStroke()
                NSBezierPath(rect: rect).stroke()
            }
        }
    }

    private func drawTextLines(on image: NSImage, lines: [TextLine]) -> NSImage {
        annotate(on: image) {
            for line in lines {
                let rect = drawingRect(line.boundingBox, imageSize: image.size)
                NSColor.systemBlue.withAlphaComponent(0.14).setFill()
                NSBezierPath(rect: rect).fill()
                NSColor.systemBlue.setStroke()
                NSBezierPath(rect: rect).stroke()
            }
        }
    }

    private func drawLayoutBands(on image: NSImage, bands: [OCRLayoutBand]) -> NSImage {
        annotate(on: image) {
            for band in bands {
                let rect = drawingRect(band.boundingBox, imageSize: image.size)
                NSColor.systemTeal.withAlphaComponent(0.10).setFill()
                NSBezierPath(rect: rect).fill()
                NSColor.systemTeal.setStroke()
                NSBezierPath(rect: rect).stroke()
            }
        }
    }

    private func drawLayoutSections(on image: NSImage, bands: [OCRLayoutBand]) -> NSImage {
        annotate(on: image) {
            for section in bands.flatMap(\.sections) {
                let rect = drawingRect(section.boundingBox, imageSize: image.size)
                NSColor.systemIndigo.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                NSColor.systemIndigo.setStroke()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).stroke()
            }
        }
    }

    private func drawMergeDecisions(on image: NSImage, decisions: [OCRMergeDecision], lines: [TextLine]) -> NSImage {
        let lineByID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        return annotate(on: image) {
            for decision in decisions {
                guard let previous = lineByID[decision.previousLineID],
                      let current = lineByID[decision.currentLineID] else {
                    continue
                }
                let previousRect = drawingRect(previous.boundingBox, imageSize: image.size)
                let currentRect = drawingRect(current.boundingBox, imageSize: image.size)
                let color: NSColor = decision.strategy == .newParagraph ? .systemRed : .systemGreen
                color.withAlphaComponent(0.18).setFill()
                NSBezierPath(rect: previousRect.union(currentRect)).fill()
                color.setStroke()
                let path = NSBezierPath()
                path.move(to: CGPoint(x: previousRect.midX, y: previousRect.midY))
                path.line(to: CGPoint(x: currentRect.midX, y: currentRect.midY))
                path.lineWidth = decision.strategy == .newParagraph ? 2 : 1
                path.stroke()
            }
        }
    }

    private func drawSegments(on image: NSImage, segments: [OverlaySegment]) -> NSImage {
        annotate(on: image) {
            for segment in segments {
                let rect = drawingRect(segment.boundingBox, imageSize: image.size)
                NSColor.systemOrange.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                NSColor.systemOrange.setStroke()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).stroke()
            }
        }
    }

    private func drawReflowBlocks(on image: NSImage, segments: [OverlaySegment]) -> NSImage {
        annotate(on: image) {
            for segment in segments where segment.reflowPreferred {
                let rect = drawingRect(segment.boundingBox, imageSize: image.size)
                NSColor.systemPink.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
                NSColor.systemPink.setStroke()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).stroke()
            }
        }
    }

    private func drawEraseBoxes(on image: NSImage, segments: [OverlaySegment]) -> NSImage {
        annotate(on: image) {
            for segment in segments {
                for box in segment.eraseBoxes {
                    let rect = drawingRect(box, imageSize: image.size)
                    NSColor.systemRed.withAlphaComponent(0.2).setFill()
                    NSBezierPath(rect: rect).fill()
                    NSColor.systemRed.setStroke()
                    NSBezierPath(rect: rect).stroke()
                }
            }
        }
    }

    private func drawDisplayRegions(on image: NSImage, regions: [OverlayDisplayRegion]) -> NSImage {
        annotate(on: image) {
            for region in regions {
                let rect = drawingRect(region.boundingBox, imageSize: image.size)
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
                color.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                color.setStroke()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).stroke()
            }
        }
    }

    private func renderErasePreview(on image: NSImage, regions: [OverlayDisplayRegion]) -> NSImage {
        annotate(on: image) {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return
            }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            for region in regions {
                for eraseBox in region.eraseBoxes {
                    let expanded = expandAndClamp(eraseBox, imageSize: image.size)
                    let drawing = drawingRect(expanded, imageSize: image.size)
                    let fill = sampleBackgroundColor(around: drawing, in: bitmap) ?? NSColor(calibratedWhite: 0.96, alpha: 1)
                    fill.setFill()
                    NSBezierPath(rect: drawing).fill()
                }
            }
        }
    }

    private func renderEraseOnly(on image: NSImage, segments: [OverlaySegment]) -> NSImage {
        annotate(on: image) {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return
            }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            for segment in segments {
                for eraseBox in segment.eraseBoxes {
                    let expanded = expandAndClamp(eraseBox, imageSize: image.size)
                    let drawing = drawingRect(expanded, imageSize: image.size)
                    let fill = sampleBackgroundColor(around: drawing, in: bitmap) ?? NSColor(calibratedWhite: 0.96, alpha: 1)
                    fill.setFill()
                    NSBezierPath(rect: drawing).fill()
                }
            }
        }
    }

    private func annotate(on image: NSImage, drawing: () -> Void) -> NSImage {
        let output = NSImage(size: image.size)
        output.lockFocus()
        defer { output.unlockFocus() }
        image.draw(in: CGRect(origin: .zero, size: image.size))
        drawing()
        return output
    }

    private func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try pngData.write(to: url)
    }

    private func drawingRect(_ rect: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: rect.minX,
            y: imageSize.height - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
        .integral
    }

    private func expandAndClamp(_ rect: CGRect, imageSize: CGSize) -> CGRect {
        let expanded = rect.insetBy(dx: -3, dy: -3)
        let bounds = CGRect(origin: .zero, size: imageSize)
        return expanded.intersection(bounds).integral
    }

    private func sampleBackgroundColor(around rect: CGRect, in bitmap: NSBitmapImageRep) -> NSColor? {
        let points = [
            CGPoint(x: rect.midX, y: rect.maxY + 2),
            CGPoint(x: rect.midX, y: rect.minY - 2),
            CGPoint(x: rect.minX - 2, y: rect.midY),
            CGPoint(x: rect.maxX + 2, y: rect.midY),
            CGPoint(x: rect.minX - 2, y: rect.minY - 2),
            CGPoint(x: rect.maxX + 2, y: rect.minY - 2),
            CGPoint(x: rect.minX - 2, y: rect.maxY + 2),
            CGPoint(x: rect.maxX + 2, y: rect.maxY + 2)
        ]

        let colors = points.compactMap { point -> NSColor? in
            let x = Int(round(point.x))
            let y = Int(round(point.y))
            guard x >= 0,
                  y >= 0,
                  x < bitmap.pixelsWide,
                  y < bitmap.pixelsHigh else {
                return nil
            }
            return bitmap.colorAt(x: x, y: y)
        }

        guard !colors.isEmpty else {
            return nil
        }

        let rgb = colors.reduce((r: CGFloat.zero, g: CGFloat.zero, b: CGFloat.zero)) { partial, color in
            let converted = color.usingColorSpace(.deviceRGB) ?? color
            return (
                partial.r + converted.redComponent,
                partial.g + converted.greenComponent,
                partial.b + converted.blueComponent
            )
        }

        let count = CGFloat(colors.count)
        return NSColor(
            calibratedRed: rgb.r / count,
            green: rgb.g / count,
            blue: rgb.b / count,
            alpha: 1
        )
    }

    private func buildReport(
        ocrSnapshot: OverlayOCRSnapshot,
        segmentation: OverlaySegmentationSnapshot,
        overlayStyle: ScreenshotTranslationOverlayStyle
    ) -> DebugReport {
        let atomCount = ocrSnapshot.textAtoms.count
        let lineCount = segmentation.textLines.count
        let segmentCount = segmentation.overlaySegments.count
        let eraseBoxCount = segmentation.overlaySegments.reduce(0) { $0 + $1.eraseBoxes.count }
        let singleLineSegments = segmentation.overlaySegments.filter { $0.lines.count <= 1 }.count
        let averageAtomsPerLine = lineCount == 0 ? 0 : Double(atomCount) / Double(lineCount)
        let averageLinesPerSegment = segmentCount == 0 ? 0 : Double(segmentation.textLines.count) / Double(segmentCount)
        let singleLineSegmentRatio = segmentCount == 0 ? 0 : Double(singleLineSegments) / Double(segmentCount)
        let layoutBands = ocrSnapshot.layoutSnapshot?.bands ?? []
        let reflowSegments = segmentation.overlaySegments.filter(\.reflowPreferred).count

        return DebugReport(
            ocrObservationCount: ocrSnapshot.ocrObservationCount,
            textBlockCount: ocrSnapshot.ocrBlocks.count,
            textAtomCount: atomCount,
            textLineCount: lineCount,
            overlaySegmentCount: segmentCount,
            averageAtomsPerLine: averageAtomsPerLine,
            averageLinesPerSegment: averageLinesPerSegment,
            singleLineSegmentRatio: singleLineSegmentRatio,
            eraseBoxCount: eraseBoxCount,
            usedVisionModel: false,
            overlayStyle: overlayStyle.rawValue,
            scaleFactor: Double(ocrSnapshot.scaleFactor),
            ocrScaleFactor: Double(ocrSnapshot.ocrScaleFactor),
            originalImageSize: ocrSnapshot.originalImageSize,
            ocrImageSize: ocrSnapshot.ocrImageSize,
            displayPointSize: ocrSnapshot.displayPointSize,
            backingScaleFactor: Double(ocrSnapshot.backingScaleFactor),
            effectiveScaleFactor: Double(ocrSnapshot.effectiveScaleFactor),
            cropOrigin: ocrSnapshot.cropOrigin,
            coordinateSpace: ocrSnapshot.coordinateSpace.rawValue,
            boxDebugInfo: ocrSnapshot.boxDebugInfo,
            layoutClusters: layoutBands.map(DebugLayoutCluster.init),
            mergeDecisions: ocrSnapshot.layoutSnapshot?.mergeDecisions.map(DebugMergeDecision.init) ?? [],
            reflowSegmentIDs: segmentation.overlaySegments.filter(\.reflowPreferred).map(\.id),
            reflowSegmentCount: reflowSegments
        )
    }
}

private struct DebugReport: Codable {
    var ocrObservationCount: Int
    var textBlockCount: Int
    var textAtomCount: Int
    var textLineCount: Int
    var overlaySegmentCount: Int
    var averageAtomsPerLine: Double
    var averageLinesPerSegment: Double
    var singleLineSegmentRatio: Double
    var eraseBoxCount: Int
    var usedVisionModel: Bool
    var overlayStyle: String
    var scaleFactor: Double
    var ocrScaleFactor: Double
    var originalImageSize: CGSize
    var ocrImageSize: CGSize
    var displayPointSize: CGSize
    var backingScaleFactor: Double
    var effectiveScaleFactor: Double
    var cropOrigin: CGPoint
    var coordinateSpace: String
    var boxDebugInfo: [OCRTextBoxDebugInfo]
    var layoutClusters: [DebugLayoutCluster]
    var mergeDecisions: [DebugMergeDecision]
    var reflowSegmentIDs: [String]
    var reflowSegmentCount: Int
}

private struct DebugLayoutCluster: Codable {
    var id: String
    var boundingBox: CGRect
    var sectionIDs: [String]

    init(_ band: OCRLayoutBand) {
        id = band.id
        boundingBox = band.boundingBox
        sectionIDs = band.sections.map(\.id)
    }
}

private struct DebugMergeDecision: Codable {
    var previousLineID: String
    var currentLineID: String
    var strategy: String
    var reason: String
    var verticalGap: CGFloat
    var horizontalOverlap: CGFloat
    var indentation: CGFloat
    var heightRatio: CGFloat

    init(_ decision: OCRMergeDecision) {
        previousLineID = decision.previousLineID
        currentLineID = decision.currentLineID
        strategy = decision.strategy.rawValue
        reason = decision.reason
        verticalGap = decision.verticalGap
        horizontalOverlap = decision.horizontalOverlap
        indentation = decision.indentation
        heightRatio = decision.heightRatio
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension DateFormatter {
    static var overlayDebugTimestamp: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }
}
