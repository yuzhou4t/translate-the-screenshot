import AppKit
import CoreGraphics
import Foundation

enum TextAtomKind: String, Codable, Equatable {
    case word
    case cjkChunk
    case punctuation
    case number
    case url
    case code
    case symbol
    case unknown
}

struct TextAtom: Identifiable, Codable, Equatable {
    var id: String
    var text: String
    var boundingBox: CGRect
    var confidence: Float
    var sourceObservationID: UUID
    var kind: TextAtomKind
}

struct TextLine: Identifiable, Codable, Equatable {
    var id: String
    var atoms: [TextAtom]
    var text: String
    var boundingBox: CGRect
    var baselineY: CGFloat
    var averageHeight: CGFloat
    var readingOrder: Int
}

enum OCRCoordinateSpace: String, Codable, Equatable {
    case pixel
}

struct OCRTextBoxDebugInfo: Codable, Equatable {
    var blockID: String
    var normalizedRect: CGRect
    var ocrPixelRect: CGRect
    var mappedPixelRect: CGRect
    var renderRect: CGRect
    var text: String
    var confidence: Float
}

struct OverlayOCRSnapshot {
    var ocrObservationCount: Int
    var ocrBlocks: [OCRTextBlock]
    var textAtoms: [TextAtom]
    var layoutSnapshot: OCRLayoutSnapshot?
    var scaleFactor: CGFloat
    var ocrScaleFactor: CGFloat
    var originalImageSize: CGSize
    var ocrImageSize: CGSize
    var displayPointSize: CGSize
    var backingScaleFactor: CGFloat
    var effectiveScaleFactor: CGFloat
    var cropOrigin: CGPoint
    var coordinateSpace: OCRCoordinateSpace
    var ocrInputImage: NSImage
    var boxDebugInfo: [OCRTextBoxDebugInfo]
}

struct OverlaySegmentationSnapshot: Equatable {
    var textLines: [TextLine]
    var overlaySegments: [OverlaySegment]
}
