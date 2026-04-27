import Foundation

enum OCRTextProcessingMode: String, CaseIterable, Codable, Equatable {
    case plainText
    case article
    case code
    case markdown
    case auto
}

struct OCRTextPostProcessingResult: Equatable {
    var text: String
    var mode: OCRTextProcessingMode
}

struct OCRTextPostProcessor: Sendable {
    func process(
        _ rawText: String,
        mode: OCRTextProcessingMode = .auto
    ) -> OCRTextPostProcessingResult {
        let normalized = normalizeInput(rawText)
        guard !normalized.isEmpty else {
            return OCRTextPostProcessingResult(
                text: "",
                mode: mode == .auto ? .plainText : mode
            )
        }

        let resolvedMode = resolveMode(for: normalized, requested: mode)
        let protected = protectURLs(in: normalized)

        let cleaned: String
        switch resolvedMode {
        case .plainText:
            cleaned = processStructuredText(
                protected.text,
                supportsMarkdown: false,
                aggressiveParagraphMerging: false
            )
        case .article:
            cleaned = processStructuredText(
                protected.text,
                supportsMarkdown: false,
                aggressiveParagraphMerging: true
            )
        case .code:
            cleaned = processCode(protected.text)
        case .markdown:
            cleaned = processStructuredText(
                protected.text,
                supportsMarkdown: true,
                aggressiveParagraphMerging: true
            )
        case .auto:
            cleaned = protected.text
        }

        let restored = restoreURLs(in: cleaned, replacements: protected.replacements)
        return OCRTextPostProcessingResult(
            text: finalize(restored),
            mode: resolvedMode
        )
    }

    private func resolveMode(for text: String, requested: OCRTextProcessingMode) -> OCRTextProcessingMode {
        guard requested == .auto else {
            return requested
        }

        if looksLikeCode(text) {
            return .code
        }
        if looksLikeMarkdown(text) {
            return .markdown
        }

        let nonEmptyLines = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return nonEmptyLines.count <= 2 ? .plainText : .article
    }

    private func processCode(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map(trimTrailingWhitespace)
        return collapseExtraBlankLines(lines.joined(separator: "\n"))
    }

    private func processStructuredText(
        _ text: String,
        supportsMarkdown: Bool,
        aggressiveParagraphMerging: Bool
    ) -> String {
        let lines = text.components(separatedBy: .newlines)
        var output: [String] = []
        var paragraphBuffer: [String] = []
        var index = 0
        var inCodeFence = false

        func flushParagraphBuffer() {
            guard !paragraphBuffer.isEmpty else {
                return
            }

            let merged = mergeParagraphLines(
                paragraphBuffer,
                aggressive: aggressiveParagraphMerging
            )
            if !merged.isEmpty {
                output.append(merged)
            }
            paragraphBuffer.removeAll()
        }

        while index < lines.count {
            let line = trimTrailingWhitespace(lines[index])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if supportsMarkdown, isFenceLine(trimmed) {
                flushParagraphBuffer()
                output.append(trimmed)
                inCodeFence.toggle()
                index += 1
                continue
            }

            if inCodeFence {
                output.append(line)
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraphBuffer()
                appendBlankLine(to: &output)
                index += 1
                continue
            }

            if let listItem = consumeListItem(
                from: lines,
                startIndex: index,
                supportsMarkdown: supportsMarkdown
            ) {
                flushParagraphBuffer()
                output.append(listItem.text)
                index = listItem.nextIndex
                continue
            }

            if supportsMarkdown, isStandaloneMarkdownLine(trimmed) {
                flushParagraphBuffer()
                output.append(normalizeMixedSpacing(trimmed))
                index += 1
                continue
            }

            if looksLikeCodeLine(line) {
                flushParagraphBuffer()
                output.append(line)
                index += 1
                continue
            }

            paragraphBuffer.append(line)
            index += 1
        }

        flushParagraphBuffer()
        return collapseExtraBlankLines(output.joined(separator: "\n"))
    }

    private func consumeListItem(
        from lines: [String],
        startIndex: Int,
        supportsMarkdown: Bool
    ) -> (text: String, nextIndex: Int)? {
        let firstLine = trimTrailingWhitespace(lines[startIndex])
        guard let prefix = listPrefix(in: firstLine) else {
            return nil
        }

        var contentLines = [prefix.content]
        var index = startIndex + 1

        while index < lines.count {
            let line = trimTrailingWhitespace(lines[index])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty ||
                listPrefix(in: line) != nil ||
                (supportsMarkdown && isFenceLine(trimmed)) ||
                (supportsMarkdown && isStandaloneMarkdownLine(trimmed)) ||
                looksLikeCodeLine(line) {
                break
            }

            contentLines.append(trimmed)
            index += 1
        }

        let mergedContent = mergeParagraphLines(contentLines, aggressive: true)
        return ("\(prefix.prefix)\(mergedContent)", index)
    }

    private func mergeParagraphLines(
        _ lines: [String],
        aggressive: Bool
    ) -> String {
        let trimmedLines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard var merged = trimmedLines.first else {
            return ""
        }

        for line in trimmedLines.dropFirst() {
            if !aggressive && !shouldMergePlainTextLine(previous: merged, next: line) {
                merged += "\n" + line
                continue
            }

            merged = joinLineFragments(merged, line)
        }

        return normalizeMixedSpacing(merged)
    }

    private func joinLineFragments(_ lhs: String, _ rhs: String) -> String {
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

    private func shouldMergePlainTextLine(previous: String, next: String) -> Bool {
        if hasHyphenatedEnglishBreak(previous, next) {
            return true
        }

        if let last = previous.last, isSentenceTerminator(last) {
            return false
        }

        if previous.count <= 36 {
            return true
        }

        if let nextFirst = next.first, nextFirst.isLowercaseASCII {
            return true
        }

        return containsCJK(previous) || containsCJK(next)
    }

    private func finalize(_ text: String) -> String {
        collapseExtraBlankLines(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeInput(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func collapseExtraBlankLines(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var output: [String] = []
        var previousWasBlank = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if !previousWasBlank, !output.isEmpty {
                    output.append("")
                }
                previousWasBlank = true
            } else {
                output.append(trimTrailingWhitespace(line))
                previousWasBlank = false
            }
        }

        return output.joined(separator: "\n")
    }

    private func appendBlankLine(to output: inout [String]) {
        guard output.last?.isEmpty != true, !output.isEmpty else {
            return
        }
        output.append("")
    }

    private func normalizeMixedSpacing(_ text: String) -> String {
        var result = ""
        let characters = Array(text)

        for index in characters.indices {
            let character = characters[index]
            guard character == " " else {
                result.append(character)
                continue
            }

            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if shouldRemoveSpaceBetween(previous, next) {
                continue
            }

            if result.last == " " {
                continue
            }

            result.append(character)
        }

        return result
    }

    private func shouldRemoveSpaceBetween(_ lhs: Character?, _ rhs: Character?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        if isCJK(lhs) && (isCJK(rhs) || rhs.isASCIIWordLike || isOpeningPunctuation(rhs)) {
            return true
        }

        if (lhs.isASCIIWordLike || isClosingPunctuation(lhs)) && isCJK(rhs) {
            return true
        }

        if isOpeningPunctuation(lhs) || isClosingPunctuation(rhs) {
            return true
        }

        return false
    }

    private func hasHyphenatedEnglishBreak(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhsLast = lhs.last,
              lhsLast == "-",
              let beforeHyphen = lhs.dropLast().last,
              let rhsFirst = rhs.first else {
            return false
        }

        return beforeHyphen.isASCIIWordLike && rhsFirst.isLowercaseASCII
    }

    private func shouldJoinWithoutSpace(_ lhs: Character?, _ rhs: Character?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        if isCJK(lhs) || isCJK(rhs) {
            return true
        }

        if isOpeningPunctuation(lhs) || isClosingPunctuation(rhs) {
            return true
        }

        return false
    }

    private func looksLikeMarkdown(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return isFenceLine(trimmed) ||
                isStandaloneMarkdownLine(trimmed) ||
                trimmed.contains("](") ||
                trimmed.hasPrefix("- [") ||
                trimmed.hasPrefix("* [")
        }
    }

    private func looksLikeCode(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        var codeScore = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            if isFenceLine(trimmed) {
                return true
            }
            if looksLikeCodeLine(line) {
                codeScore += 1
            }
            if trimmed.contains("{") || trimmed.contains("}") || trimmed.contains("->") {
                codeScore += 1
            }
        }

        return codeScore >= max(3, lines.count / 3)
    }

    private func looksLikeCodeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        if line.hasPrefix("    ") || line.hasPrefix("\t") {
            return true
        }

        let codePatterns = [
            "func ", "let ", "var ", "const ", "return ", "class ",
            "struct ", "enum ", "if ", "else", "for ", "while ",
            "import ", "public ", "private ", "protocol "
        ]

        if codePatterns.contains(where: { trimmed.hasPrefix($0) }) {
            return true
        }

        let symbols = ["{", "}", "();", "=>", "::", "</", "/>", "```"]
        return symbols.contains(where: { trimmed.contains($0) })
    }

    private func isFenceLine(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    private func isStandaloneMarkdownLine(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("|") {
            return true
        }

        if line == "---" || line == "***" || line == "___" {
            return true
        }

        return false
    }

    private func listPrefix(in line: String) -> (prefix: String, content: String)? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let body = String(line.dropFirst(indent.count))

        guard let first = body.first else {
            return nil
        }

        if "-*+•".contains(first) {
            let content = String(body.dropFirst()).trimmingLeadingWhitespace
            return ("\(indent)\(first) ", content)
        }

        var digits = ""
        for character in body {
            if character.isNumber {
                digits.append(character)
            } else {
                break
            }
        }

        if !digits.isEmpty {
            let remainder = String(body.dropFirst(digits.count))
            if let marker = remainder.first,
               [".", ")"].contains(marker),
               remainder.dropFirst().first?.isWhitespace == true {
                let content = String(remainder.dropFirst()).trimmingLeadingWhitespace
                return ("\(indent)\(digits)\(marker) ", content)
            }
        }

        return nil
    }

    private func protectURLs(in text: String) -> (text: String, replacements: [String: String]) {
        let pattern = #"https?://\S+|www\.\S+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, [:])
        }

        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )

        guard !matches.isEmpty else {
            return (text, [:])
        }

        var rewritten = text
        var replacements: [String: String] = [:]

        for (index, match) in matches.enumerated().reversed() {
            let original = nsText.substring(with: match.range)
            let token = "__TTS_URL_\(index)__"
            let range = Range(match.range, in: rewritten)!
            rewritten.replaceSubrange(range, with: token)
            replacements[token] = original
        }

        return (rewritten, replacements)
    }

    private func restoreURLs(in text: String, replacements: [String: String]) -> String {
        replacements.reduce(text) { partial, pair in
            partial.replacingOccurrences(of: pair.key, with: pair.value)
        }
    }

    private func trimTrailingWhitespace(_ line: String) -> String {
        var output = line
        while output.last?.isWhitespace == true {
            output.removeLast()
        }
        return output
    }

    private func containsCJK(_ text: String) -> Bool {
        text.contains { isCJK($0) }
    }

    private func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x3040...0x30FF).contains(scalar.value) ||
                (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    private func isSentenceTerminator(_ character: Character) -> Bool {
        ".!?;:。！？；：".contains(character)
    }

    private func isOpeningPunctuation(_ character: Character) -> Bool {
        "([{<“‘《（".contains(character)
    }

    private func isClosingPunctuation(_ character: Character) -> Bool {
        ".,!?;:%)]}>”’》），。！？；：、".contains(character)
    }
}

private extension Character {
    var isASCIIWordLike: Bool {
        unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.value < 128
        }
    }

    var isLowercaseASCII: Bool {
        unicodeScalars.allSatisfy { scalar in
            (97...122).contains(scalar.value)
        }
    }
}

private extension String {
    var trimmingLeadingWhitespace: String {
        let scalars = unicodeScalars.drop { CharacterSet.whitespacesAndNewlines.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
