import CoreGraphics
import Foundation

struct OCRTextBlockGrouper: Sendable {
    func group(_ blocks: [OCRTextBlock]) -> [OCRTextBlock] {
        guard !blocks.isEmpty else {
            return []
        }

        let sortedBlocks = sortInReadingOrder(blocks)
        let lineGroups = groupLines(sortedBlocks)
        let mergedLineBlocks = lineGroups.flatMap(clusterLineFragments)
        return mergeParagraphBlocks(mergedLineBlocks)
    }

    private func sortInReadingOrder(_ blocks: [OCRTextBlock]) -> [OCRTextBlock] {
        blocks.sorted { lhs, rhs in
            let rowThreshold = max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.4
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > rowThreshold {
                return lhs.boundingBox.midY < rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }

    private func groupLines(_ blocks: [OCRTextBlock]) -> [[OCRTextBlock]] {
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

    private func clusterLineFragments(_ line: [OCRTextBlock]) -> [OCRTextBlock] {
        let fragments = line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        guard var current = fragments.first else {
            return []
        }

        var mergedBlocks: [OCRTextBlock] = []

        for fragment in fragments.dropFirst() {
            let gap = fragment.boundingBox.minX - current.boundingBox.maxX
            let gapLimit = max(max(current.boundingBox.height, fragment.boundingBox.height) * 1.4, 24)

            if gap > gapLimit {
                mergedBlocks.append(current)
                current = fragment
            } else {
                current.text = joinInlineText(current.text, fragment.text)
                current.boundingBox = current.boundingBox.union(fragment.boundingBox)
                current.confidence = averageConfidence(current.confidence, fragment.confidence)
            }
        }

        mergedBlocks.append(current)
        return mergedBlocks
    }

    private func mergeParagraphBlocks(_ blocks: [OCRTextBlock]) -> [OCRTextBlock] {
        guard var current = blocks.first else {
            return []
        }

        var mergedBlocks: [OCRTextBlock] = []

        for next in blocks.dropFirst() {
            if shouldMergeVertically(current, next) {
                current.text = joinParagraphText(current.text, next.text)
                current.boundingBox = current.boundingBox.union(next.boundingBox)
                current.confidence = averageConfidence(current.confidence, next.confidence)
            } else {
                mergedBlocks.append(current)
                current = next
            }
        }

        mergedBlocks.append(current)
        return mergedBlocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func shouldMergeVertically(_ lhs: OCRTextBlock, _ rhs: OCRTextBlock) -> Bool {
        if isLikelyListItem(lhs.text) || isLikelyListItem(rhs.text) {
            return false
        }

        if isLikelyCodeLine(lhs.text) || isLikelyCodeLine(rhs.text) {
            return false
        }

        let verticalGap = rhs.boundingBox.minY - lhs.boundingBox.maxY
        let maxHeight = max(lhs.boundingBox.height, rhs.boundingBox.height)
        guard verticalGap >= -maxHeight * 0.25, verticalGap <= maxHeight * 0.9 else {
            return false
        }

        let leftAlignmentTolerance = max(maxHeight * 1.5, 28)
        guard abs(lhs.boundingBox.minX - rhs.boundingBox.minX) <= leftAlignmentTolerance else {
            return false
        }

        let horizontalOverlap = lhs.boundingBox.intersection(rhs.boundingBox).width
        let minWidth = max(min(lhs.boundingBox.width, rhs.boundingBox.width), 1)
        let overlapRatio = horizontalOverlap / minWidth
        guard overlapRatio >= 0.2 || abs(lhs.boundingBox.midX - rhs.boundingBox.midX) <= max(lhs.boundingBox.width, rhs.boundingBox.width) * 0.35 else {
            return false
        }

        if endsWithStrongBreak(lhs.text), startsLikeNewSection(rhs.text) {
            return false
        }

        return true
    }

    private func joinInlineText(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else {
            return rhs
        }
        guard !rhs.isEmpty else {
            return lhs
        }

        if hasHyphenatedEnglishBreak(lhs, rhs) {
            return String(lhs.dropLast()) + rhs
        }

        if shouldJoinWithoutSpace(lhs.last, rhs.first) {
            return lhs + rhs
        }

        if let rhsFirst = rhs.first, isClosingPunctuation(rhsFirst) {
            return lhs + rhs
        }

        return lhs + " " + rhs
    }

    private func joinParagraphText(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else {
            return rhs
        }
        guard !rhs.isEmpty else {
            return lhs
        }

        if lhs.contains("\n") || rhs.contains("\n") {
            return lhs + "\n" + rhs
        }

        return joinInlineText(lhs, rhs)
    }

    private func averageConfidence(_ lhs: Float, _ rhs: Float) -> Float {
        (lhs + rhs) / 2
    }

    private func hasHyphenatedEnglishBreak(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.last == "-", let rhsFirst = rhs.first else {
            return false
        }

        return rhsFirst.isLetter
    }

    private func shouldJoinWithoutSpace(_ lhs: Character?, _ rhs: Character?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        if isCJK(lhs) || isCJK(rhs) {
            return true
        }

        if isClosingPunctuation(rhs) || isOpeningPunctuation(lhs) {
            return true
        }

        return false
    }

    private func isLikelyListItem(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let bulletPrefixes = ["- ", "* ", "• ", "· ", "▪ ", "◦ ", "1. ", "2. ", "3. ", "1) ", "2) ", "3) "]
        if bulletPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return true
        }

        guard let first = trimmed.first else {
            return false
        }

        return ["•", "·", "-", "*"].contains(first)
    }

    private func isLikelyCodeLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let codeHints = ["{", "}", "()", "=>", "::", "->", "let ", "var ", "func ", "if ", "else", "return", "import "]
        let symbolCount = trimmed.filter { "{}[]()<>_=:/\\`$".contains($0) }.count

        return codeHints.contains(where: { trimmed.contains($0) }) ||
            symbolCount >= max(3, trimmed.count / 4)
    }

    private func startsLikeNewSection(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else {
            return false
        }

        return isLikelyListItem(trimmed) || first.isUppercase
    }

    private func endsWithStrongBreak(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }

        return ".!?。！？：:;；".contains(last)
    }

    private func isOpeningPunctuation(_ character: Character) -> Bool {
        "([{$#@".contains(character)
    }

    private func isClosingPunctuation(_ character: Character) -> Bool {
        ")]}>,.:;!?%".contains(character)
    }

    private func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x3040...0x30FF).contains(scalar.value) ||
                (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}
