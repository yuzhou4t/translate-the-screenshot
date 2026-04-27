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
    case imageOverlay

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
        case .imageOverlay:
            "图片覆盖翻译"
        }
    }

    var englishDisplayName: String {
        switch self {
        case .fast:
            "Fast Translation"
        case .accurate:
            "Accurate Translation"
        case .natural:
            "Natural Translation"
        case .academic:
            "Academic Translation"
        case .technical:
            "Technical Translation"
        case .ocrCleanup:
            "OCR Cleanup"
        case .bilingual:
            "Bilingual Output"
        case .polished:
            "Polished Translation"
        case .imageOverlay:
            "Image Overlay Translation"
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
            "使用论文、报告风格的正式表达，强调术语一致、逻辑清晰和客观语气。"
        case .technical:
            "保留代码、变量名、Markdown、API 名称和技术术语。"
        case .ocrCleanup:
            "修复 OCR 识别噪声并恢复段落，保留原语言和原意。"
        case .bilingual:
            "同时输出原文和译文，便于对照阅读。"
        case .polished:
            "翻译后进一步润色，使表达更清晰流畅。"
        case .imageOverlay:
            "面向图片覆盖场景输出更短、更紧凑的译文，方便放回原图文字区域。"
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
        case .imageOverlay:
            "text.below.photo"
        }
    }
}
