import AppKit
import CoreGraphics
import Foundation

enum ImageOverlayOCRStage: String, Codable, Equatable {
    case accurate

    var displayName: String {
        switch self {
        case .accurate:
            "版式 OCR"
        }
    }
}

enum ImageOverlaySegmentPhase: String, Codable, Equatable {
    case recognized
    case translating
    case translated
    case fallbackUsed
    case originalKept
    case failed
    case excluded

    var displayName: String {
        switch self {
        case .recognized:
            "已识别"
        case .translating:
            "翻译中"
        case .translated:
            "已翻译"
        case .fallbackUsed:
            "备用完成"
        case .originalKept:
            "保留原文"
        case .failed:
            "翻译失败"
        case .excluded:
            "已排除"
        }
    }
}

struct ImageOverlaySegmentState: Identifiable, Equatable {
    var segment: OverlaySegment
    var phase: ImageOverlaySegmentPhase
    var translationResult: ImageOverlayTranslationResult?
    var errorMessage: String?
    var isExcluded: Bool

    var id: String { segment.id }

    var displayText: String {
        translationResult?.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? translationResult!.translatedText
            : segment.sourceText
    }

    var canTranslate: Bool {
        segment.shouldTranslate && !isExcluded
    }

    var hasTranslatedOverlay: Bool {
        guard !isExcluded, let translationResult else {
            return false
        }

        switch translationResult.status {
        case .success, .fallbackUsed:
            let translated = translationResult.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            return !translated.isEmpty && translated != source
        case .failed, .originalKept:
            return false
        }
    }
}

struct OverlayDisplayRegion: Identifiable, Equatable {
    var segment: OverlaySegment
    var phase: ImageOverlaySegmentPhase
    var translatedText: String?
    var lineTranslations: [SegmentLineTranslation]
    var errorMessage: String?
    var isExcluded: Bool

    var id: String { segment.id }
    var boundingBox: CGRect { segment.boundingBox }
    var lineBoxes: [CGRect] { segment.lineBoxes.isEmpty ? [segment.boundingBox] : segment.lineBoxes }
    var eraseBoxes: [CGRect] {
        if !segment.eraseBoxes.isEmpty {
            return segment.eraseBoxes
        }
        return lineBoxes
    }
    var sourceText: String { segment.sourceText }

    var displayText: String {
        translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? translatedText!
            : segment.sourceText
    }

    var hasTranslatedOverlay: Bool {
        guard !isExcluded else {
            return false
        }

        switch phase {
        case .translated, .fallbackUsed:
            let translated = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            return !translated.isEmpty && translated != source
        case .recognized, .translating, .originalKept, .failed, .excluded:
            return false
        }
    }
}

struct ImageOverlaySession {
    var originalImage: NSImage
    var ocrSnapshot: OverlayOCRSnapshot
    var ocrStage: ImageOverlayOCRStage
    var textLines: [TextLine]
    var segmentStates: [ImageOverlaySegmentState]
    var zoomScale: CGFloat
    var showOCRBoxes: Bool
    var selectedSegmentID: String?
    var debugDirectory: URL?

    var segments: [OverlaySegment] {
        segmentStates.map(\.segment)
    }

    var displayRegions: [OverlayDisplayRegion] {
        segmentStates.map { state in
            OverlayDisplayRegion(
                segment: state.segment,
                phase: state.phase,
                translatedText: state.translationResult?.translatedText,
                lineTranslations: state.translationResult?.lineTranslations ?? [],
                errorMessage: state.errorMessage,
                isExcluded: state.isExcluded
            )
        }
    }

    var recognizedText: String {
        return segmentStates
            .filter { !$0.isExcluded }
            .map(\.segment.sourceText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    var translatedExportPairs: [(segment: OverlaySegment, result: ImageOverlayTranslationResult)] {
        segmentStates.compactMap { state in
            guard state.hasTranslatedOverlay, let result = state.translationResult else {
                return nil
            }
            return (state.segment, result)
        }
    }

    var summary: ImageOverlayTranslationSummary {
        let results = segmentStates.compactMap(\.translationResult)
        return results.imageOverlaySummary
    }

    static func make(
        originalImage: NSImage,
        ocrSnapshot: OverlayOCRSnapshot,
        segmentation: OverlaySegmentationSnapshot,
        stage: ImageOverlayOCRStage
    ) -> ImageOverlaySession {
        let states = segmentation.overlaySegments
            .filter { !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                ImageOverlaySegmentState(
                    segment: $0,
                    phase: $0.shouldTranslate ? .recognized : .originalKept,
                    translationResult: $0.shouldTranslate ? nil : ImageOverlayTranslationResult(
                        segmentID: $0.id,
                        sourceText: $0.sourceText,
                        translatedText: $0.sourceText,
                        lineTranslations: $0.lines.enumerated().map { index, line in
                            SegmentLineTranslation(lineIndex: index, translation: line.text)
                        },
                        status: .originalKept,
                        errorMessage: nil
                    ),
                    errorMessage: nil,
                    isExcluded: false
                )
            }

        return ImageOverlaySession(
            originalImage: originalImage,
            ocrSnapshot: ocrSnapshot,
            ocrStage: stage,
            textLines: segmentation.textLines,
            segmentStates: states,
            zoomScale: 1,
            showOCRBoxes: false,
            selectedSegmentID: states.first?.id,
            debugDirectory: nil
        )
    }
}

extension ImageOverlayTranslationStatus {
    var livePhase: ImageOverlaySegmentPhase {
        switch self {
        case .success:
            .translated
        case .fallbackUsed:
            .fallbackUsed
        case .originalKept:
            .originalKept
        case .failed:
            .failed
        }
    }
}
