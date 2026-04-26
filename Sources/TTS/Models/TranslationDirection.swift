import Foundation

enum TranslationDirection: String, Codable, CaseIterable, Identifiable, Equatable {
    case autoToChinese
    case autoToEnglish
    case englishToChinese
    case chineseToEnglish
    case japaneseToChinese
    case koreanToChinese
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .autoToChinese:
            "自动检测 -> 中文"
        case .autoToEnglish:
            "自动检测 -> 英文"
        case .englishToChinese:
            "英文 -> 中文"
        case .chineseToEnglish:
            "中文 -> 英文"
        case .japaneseToChinese:
            "日文 -> 中文"
        case .koreanToChinese:
            "韩文 -> 中文"
        case .custom:
            "自定义目标语言"
        }
    }

    var sourceLanguage: String? {
        switch self {
        case .autoToChinese, .autoToEnglish, .custom:
            nil
        case .englishToChinese:
            "en"
        case .chineseToEnglish:
            "zh-CN"
        case .japaneseToChinese:
            "ja"
        case .koreanToChinese:
            "ko"
        }
    }

    var targetLanguage: String? {
        switch self {
        case .autoToChinese, .englishToChinese, .japaneseToChinese, .koreanToChinese:
            "zh-CN"
        case .autoToEnglish, .chineseToEnglish:
            "en"
        case .custom:
            nil
        }
    }

    static func inferred(from targetLanguage: String) -> TranslationDirection {
        switch targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "zh", "zh-cn", "zh-hans", "chinese", "中文", "简体中文":
            .autoToChinese
        case "en", "en-us", "en-gb", "english", "英语":
            .autoToEnglish
        default:
            .custom
        }
    }
}
