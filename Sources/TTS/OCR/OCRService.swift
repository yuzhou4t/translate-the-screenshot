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

    init(
        postProcessor: OCRTextPostProcessor = OCRTextPostProcessor(),
        textBlockGrouper: OCRTextBlockGrouper = OCRTextBlockGrouper()
    ) {
        self.postProcessor = postProcessor
        self.textBlockGrouper = textBlockGrouper
    }

    func recognizeText(
        from imageURL: URL,
        mode: OCRRecognitionMode = .accurate
    ) async throws -> OCRResult {
        let postProcessor = self.postProcessor
        let textBlockGrouper = self.textBlockGrouper

        return try await Task.detached(priority: .userInitiated) {
            let image = try Self.loadEnhancedImage(from: imageURL, mode: mode)
            let rawBlocks = try Self.recognizeRawTextBlocks(
                in: image.recognitionImage,
                imageSize: image.originalSize,
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
            let loadedImage = try Self.loadEnhancedImage(from: image, mode: mode)
            let rawBlocks = try Self.recognizeRawTextBlocks(
                in: loadedImage.recognitionImage,
                imageSize: loadedImage.originalSize,
                mode: mode
            )
            return textBlockGrouper.group(rawBlocks)
        }.value
    }

    private struct PreparedImage {
        var recognitionImage: CGImage
        var originalSize: CGSize
    }

    private static func loadEnhancedImage(from imageURL: URL, mode: OCRRecognitionMode) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OCRServiceError.imageLoadFailed
        }

        return try prepareImage(cgImage, mode: mode)
    }

    private static func loadEnhancedImage(from image: NSImage, mode: OCRRecognitionMode) throws -> PreparedImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRServiceError.imageLoadFailed
        }

        return try prepareImage(cgImage, mode: mode)
    }

    private static func prepareImage(_ cgImage: CGImage, mode: OCRRecognitionMode) throws -> PreparedImage {
        let ciImage = CIImage(cgImage: cgImage)
        let longEdge = max(cgImage.width, cgImage.height)
        let targetLongEdge = mode == .accurate ? 2400 : 1400
        let scale = longEdge < targetLongEdge
            ? min(3.0, CGFloat(targetLongEdge) / CGFloat(max(longEdge, 1)))
            : 1.0

        var output = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        if mode == .accurate {
            if let colorControls = CIFilter(name: "CIColorControls") {
                colorControls.setValue(output, forKey: kCIInputImageKey)
                colorControls.setValue(0, forKey: kCIInputSaturationKey)
                colorControls.setValue(1.18, forKey: kCIInputContrastKey)
                colorControls.setValue(0.02, forKey: kCIInputBrightnessKey)
                if let adjusted = colorControls.outputImage {
                    output = adjusted
                }
            }

            if let sharpen = CIFilter(name: "CISharpenLuminance") {
                sharpen.setValue(output, forKey: kCIInputImageKey)
                sharpen.setValue(0.35, forKey: kCIInputSharpnessKey)
                if let sharpened = sharpen.outputImage {
                    output = sharpened
                }
            }
        }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let enhanced = context.createCGImage(output, from: output.extent) else {
            throw OCRServiceError.imageLoadFailed
        }

        return PreparedImage(
            recognitionImage: enhanced,
            originalSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private static func recognizeRawTextBlocks(
        in image: CGImage,
        imageSize: CGSize,
        mode: OCRRecognitionMode
    ) throws -> [OCRTextBlock] {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = mode.visionRecognitionLevel
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        request.minimumTextHeight = mode == .accurate ? 0.0045 : 0.012

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? [])
            .compactMap { observation -> OCRTextBlock? in
                guard let candidate = observation.topCandidates(1).first else {
                    return nil
                }

                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    return nil
                }

                return OCRTextBlock(
                    text: text,
                    boundingBox: imageBoundingBox(
                        from: observation.boundingBox,
                        imageSize: imageSize
                    ),
                    confidence: candidate.confidence
                )
            }
    }

    private static func imageBoundingBox(from normalizedRect: CGRect, imageSize: CGSize) -> CGRect {
        let width = normalizedRect.width * imageSize.width
        let height = normalizedRect.height * imageSize.height
        let x = normalizedRect.minX * imageSize.width
        let y = (1 - normalizedRect.maxY) * imageSize.height

        return CGRect(x: x, y: y, width: width, height: height)
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
