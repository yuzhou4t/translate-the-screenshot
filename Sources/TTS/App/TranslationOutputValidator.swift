import Foundation

enum TranslationOutputIssue: Equatable {
    case unchangedSource
    case missingChineseTranslation

    var errorMessage: String {
        switch self {
        case .unchangedSource:
            "翻译服务返回了与原文相同的内容。"
        case .missingChineseTranslation:
            "翻译服务没有返回简体中文译文。"
        }
    }
}

struct TranslationOutputValidator {
    static func issue(
        sourceText: String,
        translatedText: String,
        targetLanguage: String,
        translationMode: TranslationMode
    ) -> TranslationOutputIssue? {
        guard translationMode != .ocrCleanup,
              isChineseTarget(targetLanguage),
              isLikelyLatinProse(sourceText) else {
            return nil
        }

        if normalizedText(sourceText) == normalizedText(translatedText) {
            return .unchangedSource
        }

        if !containsHanCharacter(translatedText) {
            return .missingChineseTranslation
        }

        return nil
    }

    private static func isChineseTarget(_ targetLanguage: String) -> Bool {
        let normalized = targetLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "zh"
            || normalized.hasPrefix("zh-")
            || normalized.contains("chinese")
            || normalized.contains("中文")
            || normalized.contains("汉语")
    }

    private static func isLikelyLatinProse(_ text: String) -> Bool {
        guard !containsHanCharacter(text) else {
            return false
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let words = latinWordPattern.matches(in: text, range: range).compactMap { match -> String? in
            guard let wordRange = Range(match.range, in: text) else {
                return nil
            }
            return String(text[wordRange])
        }
        let naturalWords = words.filter { !isIdentifierLike($0) }
        let naturalLetterCount = naturalWords.reduce(0) { $0 + $1.count }

        if (text.contains("://") || text.contains("{") || text.contains("}"))
            && naturalWords.count < 4 {
            return false
        }

        return naturalWords.count >= 2 && naturalLetterCount >= 8
    }

    private static func isIdentifierLike(_ word: String) -> Bool {
        guard word.count > 1 else {
            return true
        }
        if word == word.uppercased() {
            return true
        }
        return word.dropFirst().contains(where: \Character.isUppercase)
    }

    private static func containsHanCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                true
            default:
                false
            }
        }
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static let latinWordPattern = try! NSRegularExpression(
        pattern: "[A-Za-z][A-Za-z'’-]*"
    )
}
