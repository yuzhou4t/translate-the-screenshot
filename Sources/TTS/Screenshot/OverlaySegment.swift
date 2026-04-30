import CoreGraphics
import Foundation

enum OverlaySegmentRole: String, Codable, CaseIterable, Equatable {
    case title
    case paragraph
    case button
    case label
    case tableCell
    case caption
    case code
    case url
    case number
    case unknown
}

struct OverlaySegment: Identifiable, Equatable {
    var id: String
    var sourceBlockIDs: [UUID]
    var sourceAtomIDs: [String]
    var sourceText: String
    var lines: [TextLine]
    var boundingBox: CGRect
    var lineBoxes: [CGRect]
    var eraseBoxes: [CGRect]
    var role: OverlaySegmentRole
    var readingOrder: Int
    var shouldTranslate: Bool
    var layoutClusterID: String?
    var reflowPreferred: Bool

    init(
        id: String,
        sourceBlockIDs: [UUID],
        sourceAtomIDs: [String],
        sourceText: String,
        lines: [TextLine],
        boundingBox: CGRect,
        lineBoxes: [CGRect],
        eraseBoxes: [CGRect],
        role: OverlaySegmentRole,
        readingOrder: Int,
        shouldTranslate: Bool,
        layoutClusterID: String? = nil,
        reflowPreferred: Bool = false
    ) {
        self.id = id
        self.sourceBlockIDs = sourceBlockIDs
        self.sourceAtomIDs = sourceAtomIDs
        self.sourceText = sourceText
        self.lines = lines
        self.boundingBox = boundingBox
        self.lineBoxes = lineBoxes
        self.eraseBoxes = eraseBoxes
        self.role = role
        self.readingOrder = readingOrder
        self.shouldTranslate = shouldTranslate
        self.layoutClusterID = layoutClusterID
        self.reflowPreferred = reflowPreferred
    }
}
