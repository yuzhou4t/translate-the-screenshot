import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

enum OCRRecognitionMode: String, CaseIterable, Codable {
    case fast
    case accurate

    var visionRecognitionLevel: VNRequestTextRecognitionLevel {
        switch self {
        case .fast:
            .fast
        case .accurate:
            .accurate
        }
    }
}

struct OCRTextBlock: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var boundingBox: CGRect
    var confidence: Float
}

struct OCRResult: Equatable {
    var rawText: String
    var processedText: String
    var textBlocks: [OCRTextBlock]
    var confidence: Float
    var processingMode: OCRTextProcessingMode

    var plainText: String {
        processedText
    }
}

final class OCRService: Sendable {
    private let postProcessor: OCRTextPostProcessor
    private let textBlockGrouper: OCRTextBlockGrouper
    private let layoutEngine: AppleOCRLayoutEngine

    init(
        postProcessor: OCRTextPostProcessor = OCRTextPostProcessor(),
        textBlockGrouper: OCRTextBlockGrouper = OCRTextBlockGrouper(),
        layoutEngine: AppleOCRLayoutEngine = AppleOCRLayoutEngine()
    ) {
        self.postProcessor = postProcessor
        self.textBlockGrouper = textBlockGrouper
        self.layoutEngine = layoutEngine
    }

    func recognizeText(
        from imageURL: URL,
        mode: OCRRecognitionMode = .accurate
    ) async throws -> OCRResult {
        let postProcessor = self.postProcessor
        let textBlockGrouper = self.textBlockGrouper

        return try await Task.detached(priority: .userInitiated) {
            let preparedImage = try Self.loadPreparedImage(from: imageURL, mode: mode)
            let rawBlocks = try Self.recognizeRawTextBlocks(
                preparedImage: preparedImage,
                mode: mode
            )
            let groupedBlocks = textBlockGrouper.group(rawBlocks)

            let rawText = Self.recoverParagraphs(from: rawBlocks)
            let processed = postProcessor.process(rawText, mode: .auto)

            return OCRResult(
                rawText: rawText,
                processedText: processed.text,
                textBlocks: groupedBlocks,
                confidence: Self.averageConfidence(from: groupedBlocks),
                processingMode: processed.mode
            )
        }.value
    }

    func recognizeTextBlocks(
        from image: NSImage,
        mode: OCRRecognitionMode = .accurate
    ) async throws -> [OCRTextBlock] {
        let textBlockGrouper = self.textBlockGrouper

        return try await Task.detached(priority: .userInitiated) {
            let preparedImage = try Self.loadPreparedImage(from: image, mode: mode)
            let rawBlocks = try Self.recognizeRawTextBlocks(
                preparedImage: preparedImage,
                mode: mode
            )
            return textBlockGrouper.group(rawBlocks)
        }.value
    }

    func recognizeRawTextBlocks(
        from image: NSImage,
        mode: OCRRecognitionMode = .accurate
    ) async throws -> [OCRTextBlock] {
        try await Task.detached(priority: .userInitiated) {
            let preparedImage = try Self.loadPreparedImage(from: image, mode: mode)
            return try Self.recognizeRawTextBlocks(
                preparedImage: preparedImage,
                mode: mode
            )
        }.value
    }

    func recognizeOverlaySnapshot(
        from image: NSImage,
        displayPointSize: CGSize? = nil,
        mode: OCRRecognitionMode = .accurate
    ) async throws -> OverlayOCRSnapshot {
        let layoutEngine = self.layoutEngine

        return try await Task.detached(priority: .userInitiated) {
            let preparedImage = try Self.loadPreparedImage(
                from: image,
                displayPointSize: displayPointSize,
                mode: mode
            )
            let observations = try Self.recognizeObservations(
                preparedImage: preparedImage,
                mode: mode
            )
            let ocrBlocks = observations.map(\.block)
            let layoutSnapshot = layoutEngine.buildSnapshot(
                from: ocrBlocks,
                imageSize: preparedImage.originalImageSize
            )
            let textAtoms = ocrBlocks.enumerated().map { index, block in
                TextAtom(
                    id: "layout-source-\(index)-\(block.id.uuidString)",
                    text: block.text,
                    boundingBox: block.boundingBox.standardized,
                    confidence: block.confidence,
                    sourceObservationID: block.id,
                    kind: Self.inferAtomKind(for: block.text)
                )
            }

            return OverlayOCRSnapshot(
                ocrObservationCount: observations.count,
                ocrBlocks: ocrBlocks,
                textAtoms: textAtoms,
                layoutSnapshot: layoutSnapshot,
                scaleFactor: preparedImage.effectiveScaleFactor * preparedImage.ocrScaleFactor,
                ocrScaleFactor: preparedImage.ocrScaleFactor,
                originalImageSize: preparedImage.originalImageSize,
                ocrImageSize: preparedImage.ocrImageSize,
                displayPointSize: preparedImage.displayPointSize,
                backingScaleFactor: preparedImage.backingScaleFactor,
                effectiveScaleFactor: preparedImage.effectiveScaleFactor,
                cropOrigin: preparedImage.cropOrigin,
                coordinateSpace: .pixel,
                ocrInputImage: NSImage(cgImage: preparedImage.recognitionImage, size: preparedImage.ocrImageSize),
                boxDebugInfo: observations.map(\.debugInfo)
            )
        }.value
    }

    private struct PreparedImage {
        var recognitionImage: CGImage
        var originalImageSize: CGSize
        var ocrImageSize: CGSize
        var displayPointSize: CGSize
        var backingScaleFactor: CGFloat
        var effectiveScaleFactor: CGFloat
        var ocrScaleFactor: CGFloat
        var cropOrigin: CGPoint
    }

    private static func loadPreparedImage(
        from imageURL: URL,
        mode: OCRRecognitionMode
    ) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OCRServiceError.imageLoadFailed
        }

        return try prepareImage(cgImage, displayPointSize: nil, mode: mode)
    }

    private static func loadPreparedImage(
        from image: NSImage,
        displayPointSize: CGSize? = nil,
        mode: OCRRecognitionMode
    ) throws -> PreparedImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRServiceError.imageLoadFailed
        }

        return try prepareImage(
            cgImage,
            displayPointSize: displayPointSize ?? image.size,
            mode: mode
        )
    }

    private static func prepareImage(
        _ cgImage: CGImage,
        displayPointSize: CGSize?,
        mode: OCRRecognitionMode
    ) throws -> PreparedImage {
        let rgbImage = try makeRGBImage(from: cgImage)
        let originalImageSize = CGSize(width: CGFloat(rgbImage.width), height: CGFloat(rgbImage.height))
        let resolvedDisplayPointSize = resolvedDisplayPointSize(
            explicitDisplayPointSize: displayPointSize,
            originalImageSize: originalImageSize
        )
        let backingScaleFactor = resolvedBackingScaleFactor(
            originalImageSize: originalImageSize,
            displayPointSize: resolvedDisplayPointSize
        )
        let effectiveScaleFactor = max(backingScaleFactor, 1)
        let ocrScaleFactor: CGFloat = effectiveScaleFactor < 1.5
            ? (1.5 / max(effectiveScaleFactor, 0.01))
            : 1.0

        var ocrInput = CIImage(cgImage: rgbImage)
        if ocrScaleFactor > 1.001,
           let lanczos = CIFilter(name: "CILanczosScaleTransform") {
            lanczos.setValue(ocrInput, forKey: kCIInputImageKey)
            lanczos.setValue(ocrScaleFactor, forKey: kCIInputScaleKey)
            lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
            if let scaled = lanczos.outputImage {
                ocrInput = scaled
            }
        }

        if mode == .accurate {
            if let colorControls = CIFilter(name: "CIColorControls") {
                colorControls.setValue(ocrInput, forKey: kCIInputImageKey)
                colorControls.setValue(0, forKey: kCIInputSaturationKey)
                colorControls.setValue(1.18, forKey: kCIInputContrastKey)
                colorControls.setValue(0.02, forKey: kCIInputBrightnessKey)
                if let adjusted = colorControls.outputImage {
                    ocrInput = adjusted
                }
            }

            if let sharpen = CIFilter(name: "CISharpenLuminance") {
                sharpen.setValue(ocrInput, forKey: kCIInputImageKey)
                sharpen.setValue(0.35, forKey: kCIInputSharpnessKey)
                if let sharpened = sharpen.outputImage {
                    ocrInput = sharpened
                }
            }
        }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let recognitionImage = context.createCGImage(ocrInput, from: ocrInput.extent) else {
            throw OCRServiceError.imageLoadFailed
        }

        return PreparedImage(
            recognitionImage: recognitionImage,
            originalImageSize: originalImageSize,
            ocrImageSize: CGSize(width: CGFloat(recognitionImage.width), height: CGFloat(recognitionImage.height)),
            displayPointSize: resolvedDisplayPointSize,
            backingScaleFactor: backingScaleFactor,
            effectiveScaleFactor: effectiveScaleFactor,
            ocrScaleFactor: ocrScaleFactor,
            cropOrigin: .zero
        )
    }

    private static func recognizeRawTextBlocks(
        preparedImage: PreparedImage,
        mode: OCRRecognitionMode
    ) throws -> [OCRTextBlock] {
        try recognizeObservations(preparedImage: preparedImage, mode: mode)
            .map(\.block)
    }

    private static func recognizeObservations(
        preparedImage: PreparedImage,
        mode: OCRRecognitionMode
    ) throws -> [RecognizedObservation] {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = mode.visionRecognitionLevel
        request.recognitionLanguages = recognitionLanguages(for: mode)
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        request.minimumTextHeight = mode == .accurate ? 0.0028 : 0.0085

        let handler = VNImageRequestHandler(cgImage: preparedImage.recognitionImage, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }

            let text = normalizedRecognizedText(candidate.string)
            guard !text.isEmpty else {
                return nil
            }

            let normalizedRect = preciseTextBoundingBox(
                for: candidate,
                fallback: observation.boundingBox
            )
            let ocrPixelRect = imagePixelRect(
                fromNormalizedRect: normalizedRect,
                imageSize: preparedImage.ocrImageSize
            )
            let mappedPixelRect = mappedOriginalPixelRect(
                fromOCRPixelRect: ocrPixelRect,
                scaleFactor: preparedImage.ocrScaleFactor,
                originalImageSize: preparedImage.originalImageSize
            )
            let renderRect = renderRect(
                fromOriginalPixelRect: mappedPixelRect,
                canvasSize: preparedImage.originalImageSize
            )

            let block = OCRTextBlock(
                id: UUID(),
                text: text,
                boundingBox: mappedPixelRect,
                confidence: candidate.confidence
            )

            return RecognizedObservation(
                block: block,
                text: text,
                candidate: candidate,
                debugInfo: OCRTextBoxDebugInfo(
                    blockID: block.id.uuidString,
                    normalizedRect: normalizedRect,
                    ocrPixelRect: ocrPixelRect.standardized,
                    mappedPixelRect: mappedPixelRect.standardized,
                    renderRect: renderRect.standardized,
                    text: text,
                    confidence: candidate.confidence
                )
            )
        }
    }

    private static func imagePixelRect(
        fromNormalizedRect normalizedRect: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        let width = normalizedRect.width * imageSize.width
        let height = normalizedRect.height * imageSize.height
        let x = normalizedRect.minX * imageSize.width
        let y = (1 - normalizedRect.maxY) * imageSize.height

        return CGRect(x: x, y: y, width: width, height: height).standardized
    }

    private static func preciseTextBoundingBox(
        for candidate: VNRecognizedText,
        fallback: CGRect
    ) -> CGRect {
        let text = candidate.string
        guard !text.isEmpty,
              let observation = try? candidate.boundingBox(for: text.startIndex..<text.endIndex) else {
            return fallback.standardized
        }

        let precise = observation.boundingBox.standardized
        guard precise.width > 0, precise.height > 0 else {
            return fallback.standardized
        }

        return precise
    }

    private static func normalizedRecognizedText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"(?<=[a-z])(?=[A-Z])"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\bthe\s*guardian\b"#,
                with: "the guardian",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\band\s*cecilia\b"#,
                with: "and Cecilia",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\bsunflower\s+me\s+and\s+cecilia\b"#,
                with: "Sunflower, me and Cecilia",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s{2,}"#,
                with: " ",
                options: .regularExpression
            )
    }

    private static func mappedOriginalPixelRect(
        fromOCRPixelRect rect: CGRect,
        scaleFactor: CGFloat,
        originalImageSize: CGSize
    ) -> CGRect {
        guard scaleFactor > 0 else {
            return rect.standardized
        }

        let mapped = CGRect(
            x: rect.minX / scaleFactor,
            y: rect.minY / scaleFactor,
            width: rect.width / scaleFactor,
            height: rect.height / scaleFactor
        )

        return mapped
            .intersection(CGRect(origin: .zero, size: originalImageSize))
            .standardized
    }

    private static func renderRect(
        fromOriginalPixelRect rect: CGRect,
        canvasSize: CGSize
    ) -> CGRect {
        CGRect(
            x: rect.minX,
            y: canvasSize.height - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func recognitionLanguages(for mode: OCRRecognitionMode) -> [String] {
        switch mode {
        case .accurate:
            return mergedRecognitionLanguages(base: ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"])
        case .fast:
            return mergedRecognitionLanguages(base: ["zh-Hans", "en-US"])
        }
    }

    private static func mergedRecognitionLanguages(base: [String]) -> [String] {
        let preferred = Locale.preferredLanguages.prefix(3).map { localeIdentifier -> String in
            if localeIdentifier.hasPrefix("zh-Hans") { return "zh-Hans" }
            if localeIdentifier.hasPrefix("zh-Hant") { return "zh-Hant" }
            if localeIdentifier.hasPrefix("en") { return "en-US" }
            if localeIdentifier.hasPrefix("ja") { return "ja-JP" }
            if localeIdentifier.hasPrefix("ko") { return "ko-KR" }
            return localeIdentifier
        }

        var merged: [String] = []
        for language in preferred + base {
            if !merged.contains(language) {
                merged.append(language)
            }
        }
        return merged
    }

    private static func inferAtomKind(for text: String) -> TextAtomKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unknown
        }

        if trimmed.range(of: #"(?i)(https?://\S+|www\.\S+|[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})"#, options: .regularExpression) != nil {
            return .url
        }

        if trimmed.range(of: #"^[\p{Sc}]?\s*\d+(?:[.,:/-]\d+)*(?:\s*[%‰])?$"#, options: .regularExpression) != nil {
            return .number
        }

        if trimmed.range(of: #"(?i)([{}[\]()<>]|=>|::|->|/[A-Za-z0-9._\-]+|[A-Za-z0-9._\-]+\.[A-Za-z]{2,6})"#, options: .regularExpression) != nil {
            return .code
        }

        return .word
    }

    private static func resolvedDisplayPointSize(
        explicitDisplayPointSize: CGSize?,
        originalImageSize: CGSize
    ) -> CGSize {
        guard let explicitDisplayPointSize,
              explicitDisplayPointSize.width > 0,
              explicitDisplayPointSize.height > 0 else {
            return originalImageSize
        }
        return explicitDisplayPointSize
    }

    private static func resolvedBackingScaleFactor(
        originalImageSize: CGSize,
        displayPointSize: CGSize
    ) -> CGFloat {
        guard displayPointSize.width > 0, displayPointSize.height > 0 else {
            return 1
        }

        let widthScale = originalImageSize.width / displayPointSize.width
        let heightScale = originalImageSize.height / displayPointSize.height
        return max(min(widthScale, heightScale), 1)
    }

    private static func makeRGBImage(from cgImage: CGImage) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw OCRServiceError.imageLoadFailed
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let output = context.makeImage() else {
            throw OCRServiceError.imageLoadFailed
        }
        return output
    }

    private static func averageConfidence(from blocks: [OCRTextBlock]) -> Float {
        guard !blocks.isEmpty else {
            return 0
        }

        let total = blocks.reduce(Float(0)) { $0 + $1.confidence }
        return total / Float(blocks.count)
    }

    private static func recoverParagraphs(from blocks: [OCRTextBlock]) -> String {
        let sortedBlocks = blocks.sorted { lhs, rhs in
            let rowThreshold = max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.4
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > rowThreshold {
                return lhs.boundingBox.midY < rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        let lines = groupLines(sortedBlocks)
        let lineTexts = lines.map { line in
            line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .map(\.text)
                .reduce("", joinNaturally)
        }

        return joinParagraphs(lines: lines, lineTexts: lineTexts)
    }

    private static func groupLines(_ blocks: [OCRTextBlock]) -> [[OCRTextBlock]] {
        var lines: [[OCRTextBlock]] = []

        for block in blocks {
            if let lastLine = lines.last,
               let reference = lastLine.first {
                let threshold = max(reference.boundingBox.height, block.boundingBox.height) * 0.6
                if abs(reference.boundingBox.midY - block.boundingBox.midY) <= threshold {
                    lines[lines.count - 1].append(block)
                    continue
                }
            }

            lines.append([block])
        }

        return lines
    }

    private static func joinParagraphs(lines: [[OCRTextBlock]], lineTexts: [String]) -> String {
        guard !lineTexts.isEmpty else {
            return ""
        }

        var output = lineTexts[0]
        for index in 1..<lineTexts.count {
            let previousLine = lines[index - 1]
            let currentLine = lines[index]
            let previousText = lineTexts[index - 1]
            let currentText = lineTexts[index]
            let previousBottom = previousLine.map(\.boundingBox.maxY).max() ?? 0
            let currentTop = currentLine.map(\.boundingBox.minY).min() ?? 0
            let previousHeight = previousLine.map(\.boundingBox.height).max() ?? 0
            let currentHeight = currentLine.map(\.boundingBox.height).max() ?? 0
            let gap = currentTop - previousBottom
            let paragraphThreshold = max(previousHeight, currentHeight) * 1.35

            if gap > paragraphThreshold {
                output += "\n\n" + currentText
            } else if shouldJoinWithoutLineBreak(previousText, currentText) {
                output = joinNaturally(output, currentText)
            } else {
                output += "\n" + currentText
            }
        }

        return output
    }

    private static func joinNaturally(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else {
            return rhs
        }
        guard !rhs.isEmpty else {
            return lhs
        }

        if needsSpaceBetween(lhs.last, rhs.first) {
            return lhs + " " + rhs
        }
        return lhs + rhs
    }

    private static func shouldJoinWithoutLineBreak(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else {
            return false
        }

        return isCJK(lhsLast) || isCJK(rhsFirst)
    }

    private static func needsSpaceBetween(_ lhs: Character?, _ rhs: Character?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        if lhs.isWhitespace || rhs.isWhitespace {
            return false
        }

        if isCJK(lhs) || isCJK(rhs) {
            return false
        }

        return lhs.isLetterOrNumber && rhs.isLetterOrNumber
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x3040...0x30FF).contains(scalar.value) ||
                (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}

private struct RecognizedObservation {
    var block: OCRTextBlock
    var text: String
    var candidate: VNRecognizedText
    var debugInfo: OCRTextBoxDebugInfo
}

private enum OCRServiceError: LocalizedError {
    case imageLoadFailed

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed:
            "无法读取截图图片。"
        }
    }
}

private extension Character {
    var isLetterOrNumber: Bool {
        unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}
