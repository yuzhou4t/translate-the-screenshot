import AppKit
import CoreGraphics
import Foundation

struct OCRLayoutObservation: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var boundingBox: CGRect
    var confidence: Float
    var readingOrder: Int
}

struct OCRLayoutBand: Identifiable, Codable, Equatable {
    var id: String
    var sections: [OCRLayoutSection]
    var boundingBox: CGRect
}

struct OCRLayoutSection: Identifiable, Codable, Equatable {
    var id: String
    var observations: [OCRLayoutObservation]
    var lines: [TextLine]
    var text: String
    var boundingBox: CGRect
    var role: OverlaySegmentRole
    var confidence: Float
    var readingOrder: Int
    var clusterID: String
    var mergeReasons: [OCRMergeDecision]
}

enum OCRMergeStrategy: String, Codable, Equatable {
    case sameLine
    case wrappedLine
    case lineBreak
    case newParagraph
}

struct OCRMergeDecision: Identifiable, Codable, Equatable {
    var id: String
    var previousLineID: String
    var currentLineID: String
    var strategy: OCRMergeStrategy
    var reason: String
    var verticalGap: CGFloat
    var horizontalOverlap: CGFloat
    var indentation: CGFloat
    var heightRatio: CGFloat
}

struct OCRLayoutSnapshot: Equatable {
    var observations: [OCRLayoutObservation]
    var bands: [OCRLayoutBand]
    var segmentation: OverlaySegmentationSnapshot

    var mergeDecisions: [OCRMergeDecision] {
        bands.flatMap(\.sections).flatMap(\.mergeReasons)
    }
}

struct AppleOCRLayoutEngine: Sendable {
    func buildSnapshot(
        from blocks: [OCRTextBlock],
        imageSize: CGSize
    ) -> OCRLayoutSnapshot {
        let observations = blocks
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted(by: readingOrderSort)
            .enumerated()
            .map { index, block in
                OCRLayoutObservation(
                    id: block.id,
                    text: block.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    boundingBox: block.boundingBox.standardized,
                    confidence: block.confidence,
                    readingOrder: index
                )
            }

        guard !observations.isEmpty else {
            return OCRLayoutSnapshot(
                observations: [],
                bands: [],
                segmentation: OverlaySegmentationSnapshot(textLines: [], overlaySegments: [])
            )
        }

        let clusters = buildLayoutClusters(from: observations, imageSize: imageSize)
        var sectionOrder = 0
        var bands: [OCRLayoutBand] = []

        for (clusterIndex, cluster) in clusters.enumerated() {
            let clusterID = "cluster-\(clusterIndex)"
            let metrics = LayoutMetrics(observations: cluster.observations)
            let lines = buildLines(
                from: cluster.observations,
                clusterID: clusterID,
                metrics: metrics
            )
            let sectionBuilds = buildSections(
                from: lines,
                clusterID: clusterID,
                metrics: metrics,
                startingReadingOrder: sectionOrder
            )
            sectionOrder += sectionBuilds.count

            guard !sectionBuilds.isEmpty else {
                continue
            }

            bands.append(
                OCRLayoutBand(
                    id: clusterID,
                    sections: sectionBuilds,
                    boundingBox: unionRect(sectionBuilds.map(\.boundingBox))
                )
            )
        }

        let orderedSections = bands.flatMap(\.sections)
            .sorted { lhs, rhs in
                if lhs.clusterID != rhs.clusterID {
                    return lhs.readingOrder < rhs.readingOrder
                }
                return lhs.boundingBox.minY < rhs.boundingBox.minY
            }
            .enumerated()
            .map { index, section in
                var next = section
                next.readingOrder = index
                return next
            }

        let sectionByID = Dictionary(uniqueKeysWithValues: orderedSections.map { ($0.id, $0) })
        let normalizedBands = bands.map { band in
            OCRLayoutBand(
                id: band.id,
                sections: band.sections.compactMap { sectionByID[$0.id] },
                boundingBox: band.boundingBox
            )
        }
        let segments = orderedSections.map(makeSegment)
        let lines = orderedSections.flatMap(\.lines)

        return OCRLayoutSnapshot(
            observations: observations,
            bands: normalizedBands,
            segmentation: OverlaySegmentationSnapshot(textLines: lines, overlaySegments: segments)
        )
    }

    private func buildLayoutClusters(
        from observations: [OCRLayoutObservation],
        imageSize: CGSize
    ) -> [LayoutCluster] {
        let primaryColumns = splitByMajorGutters(observations, imageSize: imageSize)
        var clusters: [LayoutCluster] = []

        for column in primaryColumns {
            let metrics = LayoutMetrics(observations: column)
            let lines = buildLines(from: column, clusterID: "candidate", metrics: metrics)
            let lineGroups = splitLinesByLargeVerticalWhitespace(lines, metrics: metrics)
            for group in lineGroups {
                let observationIDs = Set(group.flatMap(\.atoms).map(\.sourceObservationID))
                let clusterObservations = column
                    .filter { observationIDs.contains($0.id) }
                    .sorted(by: readingOrderSort)
                guard !clusterObservations.isEmpty else {
                    continue
                }
                clusters.append(
                    LayoutCluster(
                        observations: clusterObservations,
                        boundingBox: unionRect(clusterObservations.map(\.boundingBox))
                    )
                )
            }
        }

        return clusters.sorted { lhs, rhs in
            if abs(lhs.boundingBox.minX - rhs.boundingBox.minX) > max(imageSize.width * 0.12, 120) {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return lhs.boundingBox.minY < rhs.boundingBox.minY
        }
    }

    private func splitByMajorGutters(
        _ observations: [OCRLayoutObservation],
        imageSize: CGSize
    ) -> [[OCRLayoutObservation]] {
        guard observations.count > 2 else {
            return [observations.sorted(by: readingOrderSort)]
        }

        let metrics = LayoutMetrics(observations: observations)
        let sortedX = observations.sorted { lhs, rhs in
            lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        var splitIndexes: [Int] = []

        for index in 1..<sortedX.count {
            let previousMaxX = sortedX[..<index].map(\.boundingBox.maxX).max() ?? sortedX[index - 1].boundingBox.maxX
            let currentMinX = sortedX[index].boundingBox.minX
            let gap = currentMinX - previousMaxX
            let leftCount = index
            let rightCount = sortedX.count - index
            let minSideCount = min(leftCount, rightCount)
            let threshold = max(imageSize.width * 0.045, metrics.medianLineHeight * 2.7, 48)

            if gap > threshold, minSideCount >= 2 {
                splitIndexes.append(index)
            }
        }

        guard !splitIndexes.isEmpty else {
            return [observations.sorted(by: readingOrderSort)]
        }

        var output: [[OCRLayoutObservation]] = []
        var start = 0
        for splitIndex in splitIndexes {
            let slice = Array(sortedX[start..<splitIndex])
            if !slice.isEmpty {
                output.append(slice.sorted(by: readingOrderSort))
            }
            start = splitIndex
        }
        let tail = Array(sortedX[start...])
        if !tail.isEmpty {
            output.append(tail.sorted(by: readingOrderSort))
        }

        return output
    }

    private func splitLinesByLargeVerticalWhitespace(
        _ lines: [TextLine],
        metrics: LayoutMetrics
    ) -> [[TextLine]] {
        guard let first = lines.first else {
            return []
        }

        var groups: [[TextLine]] = [[first]]
        for line in lines.dropFirst() {
            let previous = groups[groups.count - 1].last!
            let gap = line.boundingBox.minY - previous.boundingBox.maxY
            let sameColumn = horizontalOverlapRatio(previous.boundingBox, line.boundingBox) >= 0.16 ||
                abs(previous.boundingBox.minX - line.boundingBox.minX) <= metrics.indentationThreshold * 2.2
            let listBoundary = startsListItem(line.text) && !startsListItem(previous.text)
            let whitespaceThreshold = max(metrics.bigLineSpacingThreshold * (sameColumn ? 2.4 : 1.1), metrics.medianLineHeight * 2.6)

            if gap > whitespaceThreshold || listBoundary {
                groups.append([line])
            } else {
                groups[groups.count - 1].append(line)
            }
        }

        return groups
    }

    private func buildSections(
        from lines: [TextLine],
        clusterID: String,
        metrics: LayoutMetrics,
        startingReadingOrder: Int
    ) -> [OCRLayoutSection] {
        guard let first = lines.first else {
            return []
        }

        var rawSections: [(lines: [TextLine], decisions: [OCRMergeDecision])] = [([first], [])]

        for line in lines.dropFirst() {
            let previous = rawSections[rawSections.count - 1].lines.last!
            let decision = mergeDecision(
                previous: previous,
                current: line,
                sectionLines: rawSections[rawSections.count - 1].lines,
                metrics: metrics
            )

            if decision.strategy == .wrappedLine || decision.strategy == .sameLine {
                rawSections[rawSections.count - 1].lines.append(line)
                rawSections[rawSections.count - 1].decisions.append(decision)
            } else {
                rawSections.append(([line], [decision]))
            }
        }

        return rawSections.enumerated().map { index, section in
            makeSection(
                lines: section.lines,
                clusterID: clusterID,
                mergeReasons: section.decisions,
                readingOrder: startingReadingOrder + index
            )
        }
    }

    private func buildLines(
        from observations: [OCRLayoutObservation],
        clusterID: String,
        metrics: LayoutMetrics
    ) -> [TextLine] {
        let sorted = observations.sorted(by: readingOrderSort)
        var groups: [[OCRLayoutObservation]] = []

        for observation in sorted {
            if let lastGroup = groups.last,
               let reference = lastGroup.first,
               belongsOnSameLine(reference, observation, currentLine: lastGroup, metrics: metrics) {
                groups[groups.count - 1].append(observation)
            } else {
                groups.append([observation])
            }
        }

        return groups.enumerated().map { index, group in
            let ordered = group.sorted { lhs, rhs in
                lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            let atoms = ordered.map(makeAtom)
            let text = ordered.map(\.text).reduce("", joinInline)
            let box = unionRect(ordered.map(\.boundingBox))
            let averageHeight = ordered.map(\.boundingBox.height).reduce(0, +) / CGFloat(ordered.count)

            return TextLine(
                id: "\(clusterID)-line-\(index)-\(ordered.first?.id.uuidString ?? UUID().uuidString)",
                atoms: atoms,
                text: text,
                boundingBox: box,
                baselineY: box.maxY,
                averageHeight: averageHeight,
                readingOrder: index
            )
        }
    }

    private func belongsOnSameLine(
        _ reference: OCRLayoutObservation,
        _ candidate: OCRLayoutObservation,
        currentLine: [OCRLayoutObservation],
        metrics: LayoutMetrics
    ) -> Bool {
        let referenceBox = reference.boundingBox
        let candidateBox = candidate.boundingBox
        let maxHeight = max(referenceBox.height, candidateBox.height, 1)
        let verticalOverlap = verticalOverlapRatio(referenceBox, candidateBox)
        let baselineDelta = abs(referenceBox.midY - candidateBox.midY)
        guard verticalOverlap >= 0.42 || baselineDelta <= maxHeight * 0.32 else {
            return false
        }

        let currentBox = unionRect(currentLine.map(\.boundingBox))
        let gap = candidateBox.minX - currentBox.maxX
        if gap < -maxHeight * 0.18 {
            return true
        }

        let currentText = currentLine.map(\.text).joined(separator: " ")
        let candidateText = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let protected = looksLikeProtectedText(currentText) || looksLikeProtectedText(candidate.text)
        let shortContinuation = compactTextLength(currentText) <= 6 || compactTextLength(candidate.text) <= 6
        let cjkPair = containsCJK(currentText) || containsCJK(candidateText)
        let punctuationContinuation = candidateText.first.map {
            "，,。.!！?？:：;；)]）】".contains($0)
        } ?? false

        let detachedPhraseGap = max(metrics.characterWidth * 1.55, maxHeight * 0.75, 18)
        if gap > detachedPhraseGap,
           !punctuationContinuation,
           !isFirstCharLowercaseOrContinuation(candidateText),
           (isPhraseLikeChunk(currentText) || isPhraseLikeChunk(candidateText)) {
            return false
        }

        let threshold: CGFloat
        if protected {
            threshold = max(metrics.characterWidth * 2.2, maxHeight * 1.4, 28)
        } else if cjkPair, !shortContinuation, !punctuationContinuation {
            threshold = max(metrics.characterWidth * 1.45, maxHeight * 0.8, 18)
        } else {
            threshold = max(metrics.characterWidth * (shortContinuation ? 3.4 : 2.1), maxHeight * (shortContinuation ? 1.9 : 1.25), 26)
        }

        return gap <= threshold
    }

    private func mergeDecision(
        previous: TextLine,
        current: TextLine,
        sectionLines: [TextLine],
        metrics: LayoutMetrics
    ) -> OCRMergeDecision {
        let previousText = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentText = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let averageHeight = max(previous.averageHeight, current.averageHeight, 1)
        let verticalGap = current.boundingBox.minY - previous.boundingBox.maxY
        let heightRatio = ratio(previous.averageHeight, current.averageHeight)
        let overlap = horizontalOverlapRatio(previous.boundingBox, current.boundingBox)
        let indentation = current.boundingBox.minX - previous.boundingBox.minX
        let leftAligned = abs(indentation) <= metrics.indentationThreshold
        let centerAligned = abs(previous.boundingBox.midX - current.boundingBox.midX) <= metrics.indentationThreshold * 1.2
        let previousShortLabel = isShortLabel(previous)
        let currentShortLabel = isShortLabel(current)

        func decision(_ strategy: OCRMergeStrategy, _ reason: String) -> OCRMergeDecision {
            OCRMergeDecision(
                id: "\(previous.id)->\(current.id)",
                previousLineID: previous.id,
                currentLineID: current.id,
                strategy: strategy,
                reason: reason,
                verticalGap: verticalGap,
                horizontalOverlap: overlap,
                indentation: indentation,
                heightRatio: heightRatio
            )
        }

        guard !previousText.isEmpty, !currentText.isEmpty else {
            return decision(.newParagraph, "empty-line")
        }

        if startsListItem(currentText) {
            return decision(.newParagraph, "list-item-start")
        }

        if previousShortLabel || currentShortLabel {
            if verticalGap <= max(metrics.tightLineSpacingThreshold, averageHeight * 0.5),
               (leftAligned || centerAligned || overlap >= 0.5),
               heightRatio <= 1.55 {
                return decision(.wrappedLine, "short-label-tight-stack")
            }
            return decision(.newParagraph, "short-label-boundary")
        }

        if verticalGap > metrics.bigLineSpacingThreshold {
            return decision(.newParagraph, "big-line-spacing")
        }

        if heightRatio > 1.65 {
            return decision(.newParagraph, "font-size-change")
        }

        if startsListItem(previousText), verticalGap <= metrics.relaxedLineSpacingThreshold {
            return decision(.wrappedLine, "list-continuation")
        }

        if previousText.hasSuffix(":") || previousText.hasSuffix("：") {
            if verticalGap <= metrics.relaxedLineSpacingThreshold, overlap >= 0.22 || leftAligned {
                return decision(.wrappedLine, "colon-continuation")
            }
            return decision(.newParagraph, "colon-gap")
        }

        if endsSentence(previousText),
           verticalGap > metrics.tightLineSpacingThreshold,
           !isFirstCharLowercaseOrContinuation(currentText) {
            return decision(.newParagraph, "sentence-ended")
        }

        if leftAligned || overlap >= 0.5 {
            return decision(.wrappedLine, "aligned-wrap")
        }

        if indentation > 0,
           indentation <= metrics.indentationThreshold * 2.6,
           !endsSentence(previousText) {
            return decision(.wrappedLine, "positive-indent-continuation")
        }

        let previousLong = previous.boundingBox.width >= max(metrics.maxLineWidth * 0.58, metrics.characterWidth * 10)
        if previousLong,
           !endsSentence(previousText),
           overlap >= 0.22,
           verticalGap <= metrics.relaxedLineSpacingThreshold {
            return decision(.wrappedLine, "long-line-continuation")
        }

        return decision(.newParagraph, "layout-boundary")
    }

    private func makeSection(
        lines: [TextLine],
        clusterID: String,
        mergeReasons: [OCRMergeDecision],
        readingOrder: Int
    ) -> OCRLayoutSection {
        let boundingBox = unionRect(lines.map(\.boundingBox))
        let text = lines.map(\.text).joined(separator: "\n")
        let observations = lines.flatMap(\.atoms).map { atom in
            OCRLayoutObservation(
                id: atom.sourceObservationID,
                text: atom.text,
                boundingBox: atom.boundingBox,
                confidence: atom.confidence,
                readingOrder: lines.first?.readingOrder ?? readingOrder
            )
        }
        let confidence = observations.isEmpty ? 0 : observations.map(\.confidence).reduce(0, +) / Float(observations.count)
        let role = inferRole(text: text, boundingBox: boundingBox, lines: lines)

        return OCRLayoutSection(
            id: "\(clusterID)-section-\(readingOrder)-\(observations.first?.id.uuidString ?? UUID().uuidString)",
            observations: observations,
            lines: lines,
            text: text,
            boundingBox: boundingBox,
            role: role,
            confidence: confidence,
            readingOrder: readingOrder,
            clusterID: clusterID,
            mergeReasons: mergeReasons
        )
    }

    private func makeSegment(from section: OCRLayoutSection) -> OverlaySegment {
        let lineBoxes = section.lines.map(\.boundingBox).map(expandedEraseRect)
        return OverlaySegment(
            id: section.id,
            sourceBlockIDs: unique(section.observations.map(\.id)),
            sourceAtomIDs: section.lines.flatMap(\.atoms).map(\.id),
            sourceText: section.text,
            lines: section.lines,
            boundingBox: section.boundingBox.standardized,
            lineBoxes: section.lines.map(\.boundingBox).map(\.standardized),
            eraseBoxes: lineBoxes,
            role: section.role,
            readingOrder: section.readingOrder,
            shouldTranslate: shouldTranslate(role: section.role, text: section.text),
            layoutClusterID: section.clusterID,
            reflowPreferred: shouldPreferReflow(section)
        )
    }

    private func makeAtom(from observation: OCRLayoutObservation) -> TextAtom {
        TextAtom(
            id: "layout-atom-\(observation.id.uuidString)",
            text: observation.text,
            boundingBox: observation.boundingBox.standardized,
            confidence: observation.confidence,
            sourceObservationID: observation.id,
            kind: inferAtomKind(for: observation.text)
        )
    }

    private func inferRole(
        text: String,
        boundingBox: CGRect,
        lines: [TextLine]
    ) -> OverlaySegmentRole {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isURL(trimmed) { return .url }
        if isCodeLike(trimmed) { return .code }
        if isNumberOnly(trimmed) { return .number }

        let medianHeight = median(lines.map(\.averageHeight))
        if lines.count == 1,
           let line = lines.first,
           line.averageHeight >= medianHeight * 1.2,
           trimmed.count <= 80 {
            return .title
        }

        if startsListItem(trimmed) {
            return .paragraph
        }

        if lines.count == 1, isShortLabel(lines[0]) {
            return .label
        }

        if boundingBox.height <= medianHeight * 1.35, compactTextLength(trimmed) <= 18 {
            return .caption
        }

        return .paragraph
    }

    private func shouldPreferReflow(_ section: OCRLayoutSection) -> Bool {
        switch section.role {
        case .paragraph:
            return section.lines.count >= 2 || compactTextLength(section.text) >= 22
        case .title:
            return section.lines.count >= 2
        case .caption, .label, .button, .tableCell, .unknown:
            return false
        case .code, .url, .number:
            return false
        }
    }

    private func shouldTranslate(role: OverlaySegmentRole, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        switch role {
        case .code, .url, .number:
            return false
        case .title, .paragraph, .button, .label, .tableCell, .caption, .unknown:
            return true
        }
    }

    private func readingOrderSort(_ lhs: OCRTextBlock, _ rhs: OCRTextBlock) -> Bool {
        let rowThreshold = max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.5
        if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > rowThreshold {
            return lhs.boundingBox.midY < rhs.boundingBox.midY
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
    }

    private func readingOrderSort(_ lhs: OCRLayoutObservation, _ rhs: OCRLayoutObservation) -> Bool {
        let rowThreshold = max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.42
        if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > rowThreshold {
            return lhs.boundingBox.midY < rhs.boundingBox.midY
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
    }

    private func joinInline(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        if lhs.last == "-", rhs.first?.isLetter == true {
            return String(lhs.dropLast()) + rhs
        }
        if needsNoSpace(lhs.last, rhs.first) {
            return lhs + rhs
        }
        return lhs + " " + rhs
    }

    private func needsNoSpace(_ lhs: Character?, _ rhs: Character?) -> Bool {
        guard let lhs, let rhs else { return false }
        if isCJK(lhs) || isCJK(rhs) { return true }
        if ")]}>,.:;!?%".contains(rhs) { return true }
        if "([{$#@".contains(lhs) { return true }
        return false
    }

    private func expandedEraseRect(_ rect: CGRect) -> CGRect {
        let insetX = min(max(rect.height * 0.08, 1.5), 4)
        let insetY = min(max(rect.height * 0.07, 1), 2.5)
        return rect.insetBy(dx: -insetX, dy: -insetY).standardized
    }

    private func verticalOverlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        guard overlap > 0 else { return 0 }
        return overlap / max(min(lhs.height, rhs.height), 1)
    }

    private func horizontalOverlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)
        guard overlap > 0 else { return 0 }
        return overlap / max(min(lhs.width, rhs.width), 1)
    }

    private func ratio(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        max(lhs, rhs, 1) / max(min(lhs, rhs), 1)
    }

    private func unionRect(_ rects: [CGRect]) -> CGRect {
        guard let first = rects.first else {
            return .zero
        }
        return rects.dropFirst().reduce(first.standardized) { $0.union($1.standardized) }.standardized
    }

    private func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var output: [UUID] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            output.append(id)
        }
        return output
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func startsListItem(_ text: String) -> Bool {
        text.range(of: #"^\s*(?:\d+[\).、]|[A-Za-z][\).]|[•\-])\s*"#, options: .regularExpression) != nil
    }

    private func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".。!！?？;；。\"”’".contains(last)
    }

    private func isFirstCharLowercaseOrContinuation(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return false
        }
        return first.isLowercase || "，,、：:；;)）]】".contains(first)
    }

    private func isShortLabel(_ line: TextLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = compactTextLength(text)
        guard length <= 12 else {
            return false
        }
        if startsListItem(text) {
            return false
        }
        return line.boundingBox.width <= max(line.averageHeight * 9.5, CGFloat(length) * max(line.averageHeight * 0.9, 10))
    }

    private func isPhraseLikeChunk(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard compactTextLength(trimmed) >= 7 else {
            return false
        }
        return trimmed.contains(where: \.isWhitespace) ||
            containsCJK(trimmed) ||
            trimmed.range(of: #"[A-Z][a-z]+.*[A-Z][a-z]+"#, options: .regularExpression) != nil
    }

    private func compactTextLength(_ text: String) -> Int {
        text.filter { !$0.isWhitespace && !$0.isNewline }.count
    }

    private func looksLikeProtectedText(_ text: String) -> Bool {
        isURL(text) || isCodeLike(text) || isNumberOnly(text)
    }

    private func inferAtomKind(for text: String) -> TextAtomKind {
        if isURL(text) { return .url }
        if isNumberOnly(text) { return .number }
        if isCodeLike(text) { return .code }
        if text.unicodeScalars.allSatisfy({ scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                CharacterSet.punctuationCharacters.contains(scalar)
        }) {
            return .cjkChunk
        }
        return .word
    }

    private func isURL(_ text: String) -> Bool {
        text.range(of: #"(?i)(https?://\S+|www\.\S+|[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})"#, options: .regularExpression) != nil
    }

    private func isNumberOnly(_ text: String) -> Bool {
        text.range(of: #"^[\p{Sc}]?\s*\d+(?:[.,:/\-]\d+)*(?:\s*[%‰])?$"#, options: .regularExpression) != nil
    }

    private func isCodeLike(_ text: String) -> Bool {
        text.range(of: #"(?i)([{}[\]<>]|=>|::|->|/[A-Za-z0-9._\-]+|[A-Za-z0-9._\-]+\.[A-Za-z]{2,6})"#, options: .regularExpression) != nil
    }

    private func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x3040...0x30FF).contains(scalar.value) ||
                (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    private func containsCJK(_ text: String) -> Bool {
        text.contains { isCJK($0) }
    }
}

private struct LayoutCluster {
    var observations: [OCRLayoutObservation]
    var boundingBox: CGRect
}

private struct LayoutMetrics {
    var medianLineHeight: CGFloat
    var averageLineHeight: CGFloat
    var characterWidth: CGFloat
    var maxLineWidth: CGFloat
    var indentationThreshold: CGFloat
    var tightLineSpacingThreshold: CGFloat
    var relaxedLineSpacingThreshold: CGFloat
    var bigLineSpacingThreshold: CGFloat

    init(observations: [OCRLayoutObservation]) {
        let heights = observations.map { max($0.boundingBox.height, 1) }
        medianLineHeight = LayoutMetrics.median(heights)
        averageLineHeight = heights.isEmpty ? 1 : heights.reduce(0, +) / CGFloat(heights.count)
        maxLineWidth = observations.map(\.boundingBox.width).max() ?? 1

        let characterWidths = observations.map { observation in
            observation.boundingBox.width / CGFloat(max(observation.text.filter { !$0.isWhitespace }.count, 1))
        }
        characterWidth = max(LayoutMetrics.median(characterWidths), medianLineHeight * 0.48, 6)
        indentationThreshold = max(characterWidth * 2.1, medianLineHeight * 0.85, 16)
        tightLineSpacingThreshold = max(medianLineHeight * 0.55, 8)
        relaxedLineSpacingThreshold = max(medianLineHeight * 1.35, 20)
        bigLineSpacingThreshold = max(medianLineHeight * 1.9, 32)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else {
            return 1
        }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
