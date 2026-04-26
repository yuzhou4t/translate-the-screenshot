import Foundation

enum TranslationMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case fast
    case accurate
    case natural
    case academic
    case technical
    case ocrCleanup
    case bilingual
    case polished

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast:
            "快速翻译"
        case .accurate:
            "准确翻译"
        case .natural:
            "自然表达"
        case .academic:
            "学术翻译"
        case .technical:
            "技术翻译"
        case .ocrCleanup:
            "OCR 修复翻译"
        case .bilingual:
            "双语输出"
        case .polished:
            "翻译并润色"
        }
    }

    var description: String {
        switch self {
        case .fast:
            "快速给出简洁译文，适合临时理解屏幕内容。"
        case .accurate:
            "忠实保留原文含义、语气和信息层级。"
        case .natural:
            "在准确基础上，让译文更符合目标语言的自然表达。"
        case .academic:
            "使用正式、严谨、术语稳定的学术表达。"
        case .technical:
            "保留代码、变量名、Markdown、API 名称和技术术语。"
        case .ocrCleanup:
            "修复 OCR 识别噪声并恢复段落，保留原语言和原意。"
        case .bilingual:
            "同时输出原文和译文，便于对照阅读。"
        case .polished:
            "翻译后进一步润色，使表达更清晰流畅。"
        }
    }

    var systemImage: String {
        switch self {
        case .fast:
            "bolt"
        case .accurate:
            "checkmark.seal"
        case .natural:
            "text.bubble"
        case .academic:
            "graduationcap"
        case .technical:
            "chevron.left.forwardslash.chevron.right"
        case .ocrCleanup:
            "text.viewfinder"
        case .bilingual:
            "textformat.abc"
        case .polished:
            "wand.and.stars"
        }
    }

    var systemPrompt: String {
        switch self {
        case .fast:
            "You are a fast translation engine. Translate quickly and concisely. Return only the translation."
        case .accurate:
            "You are an accurate translation engine. Preserve the original meaning, tone, terminology, formatting, and information order. Return only the translation."
        case .natural:
            "You are a natural translation editor. Translate faithfully, then phrase the result in fluent, idiomatic target-language expression. Return only the translation."
        case .academic:
            "You are an academic translation engine. Use formal, precise, rigorous wording. Keep terminology consistent and avoid casual phrasing. Return only the translation."
        case .technical:
            "You are a technical translation engine. Preserve code, variable names, Markdown, API names, commands, URLs, and technical identifiers exactly unless they are natural-language prose. Return only the translation."
        case .ocrCleanup:
            "You are an OCR cleanup engine. Repair obvious OCR errors, restore paragraph structure, and remove recognition noise. Preserve the original language and meaning. Do not translate or rewrite beyond cleanup. Return only the cleaned text."
        case .bilingual:
            "You are a bilingual translation engine. Output the original text and the translation in a clear two-part format. Preserve formatting where useful."
        case .polished:
            "You are a translation and polishing editor. Translate accurately, then polish the target-language expression for clarity, flow, and readability without adding new meaning. Return only the polished translation."
        }
    }

    var userPromptTemplate: String {
        switch self {
        case .fast:
            "Translate the following text into {{targetLanguage}} quickly and concisely:\n\n{{text}}"
        case .accurate:
            "Translate the following text into {{targetLanguage}} as accurately as possible:\n\n{{text}}"
        case .natural:
            "Translate the following text into natural {{targetLanguage}} while preserving the original meaning:\n\n{{text}}"
        case .academic:
            "Translate the following text into formal academic {{targetLanguage}}, keeping terminology stable:\n\n{{text}}"
        case .technical:
            "Translate the following technical text into {{targetLanguage}}. Preserve code, variables, Markdown, API names, commands, URLs, and identifiers:\n\n{{text}}"
        case .ocrCleanup:
            "Clean up likely OCR errors and restore paragraphs in the following text. Preserve the original language and meaning. Do not translate:\n\n{{text}}"
        case .bilingual:
            "Create a bilingual output for the following text. Include the original text and the {{targetLanguage}} translation:\n\n{{text}}"
        case .polished:
            "Translate the following text into {{targetLanguage}}, then polish the expression for clarity and readability:\n\n{{text}}"
        }
    }

    func userPrompt(text: String, targetLanguage: String) -> String {
        userPromptTemplate
            .replacingOccurrences(of: "{{targetLanguage}}", with: targetLanguage)
            .replacingOccurrences(of: "{{text}}", with: text)
    }
}
