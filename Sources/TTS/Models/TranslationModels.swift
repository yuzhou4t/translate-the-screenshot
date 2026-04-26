import Foundation

enum TranslationProviderID: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "openai-compatible"
    case myMemory = "mymemory"
    case deepL = "deepl"
    case google = "google"
    case bing = "bing"
    case baidu = "baidu"
    case tencent = "tencent"
    case volcengine = "volcengine"
    case glm4Flash = "glm-4-flash"
    case siliconFlow = "siliconflow"
    case localOCR = "local-ocr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible:
            "OpenAI 兼容接口"
        case .myMemory:
            "MyMemory 免费测试"
        case .deepL:
            "DeepL"
        case .google:
            "Google"
        case .bing:
            "Bing"
        case .baidu:
            "百度翻译"
        case .tencent:
            "腾讯翻译"
        case .volcengine:
            "火山翻译"
        case .glm4Flash:
            "GLM-4-Flash"
        case .siliconFlow:
            "硅基流动"
        case .localOCR:
            "本地 OCR"
        }
    }

    var isTranslationProvider: Bool {
        switch self {
        case .openAICompatible, .myMemory, .deepL, .google, .bing, .baidu, .tencent, .volcengine, .glm4Flash, .siliconFlow:
            true
        case .localOCR:
            false
        }
    }
}

enum TranslationProviderType: String, Codable, CaseIterable, Identifiable {
    case openAICompatible
    case myMemory
    case deepL
    case google
    case bing
    case baidu
    case tencent
    case volcengine
    case glm4Flash
    case siliconFlow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible:
            "OpenAI 兼容接口"
        case .myMemory:
            "MyMemory 免费测试"
        case .deepL:
            "DeepL"
        case .google:
            "Google"
        case .bing:
            "Bing"
        case .baidu:
            "百度翻译"
        case .tencent:
            "腾讯翻译"
        case .volcengine:
            "火山翻译"
        case .glm4Flash:
            "GLM-4-Flash"
        case .siliconFlow:
            "硅基流动"
        }
    }
}

struct ProviderConfig: Identifiable, Codable, Equatable {
    var id: TranslationProviderID
    var displayName: String
    var type: TranslationProviderType
    var isEnabled: Bool
    var priority: Int
    var endpoint: URL?
    var apiKeyRef: String?
    var appID: String?
    var secretKey: String?
    var timeout: TimeInterval
    var model: String?
    var shouldFallbackOnAuthFailure: Bool

    static let openAICompatibleDefault = ProviderConfig(
        id: .openAICompatible,
        displayName: TranslationProviderID.openAICompatible.displayName,
        type: .openAICompatible,
        isEnabled: false,
        priority: 10,
        endpoint: URL(string: "https://api.openai.com/v1/chat/completions"),
        apiKeyRef: TranslationProviderID.openAICompatible.rawValue,
        appID: nil,
        secretKey: nil,
        timeout: 30,
        model: "gpt-4o-mini",
        shouldFallbackOnAuthFailure: true
    )

    static let myMemoryDefault = ProviderConfig(
        id: .myMemory,
        displayName: TranslationProviderID.myMemory.displayName,
        type: .myMemory,
        isEnabled: true,
        priority: 20,
        endpoint: URL(string: "https://api.mymemory.translated.net/get"),
        apiKeyRef: nil,
        appID: nil,
        secretKey: nil,
        timeout: 30,
        model: nil,
        shouldFallbackOnAuthFailure: true
    )

    static func placeholder(id: TranslationProviderID, type: TranslationProviderType, priority: Int) -> ProviderConfig {
        let endpoint: URL?
        let model: String?

        switch type {
        case .deepL:
            endpoint = URL(string: "https://api-free.deepl.com/v2/translate")
            model = nil
        case .google:
            endpoint = URL(string: "https://translation.googleapis.com/language/translate/v2")
            model = nil
        case .bing:
            endpoint = URL(string: "https://api.cognitive.microsofttranslator.com/translate")
            model = nil
        case .baidu:
            endpoint = URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")
            model = nil
        case .tencent:
            endpoint = URL(string: "https://tmt.tencentcloudapi.com")
            model = "ap-guangzhou"
        case .volcengine:
            endpoint = URL(string: "https://translate.volcengineapi.com")
            model = "cn-north-1"
        case .glm4Flash:
            endpoint = URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions")
            model = "glm-4-flash-250414"
        case .siliconFlow:
            endpoint = URL(string: "https://api.siliconflow.cn/v1/chat/completions")
            model = "Qwen/Qwen2.5-7B-Instruct"
        case .openAICompatible, .myMemory:
            endpoint = nil
            model = nil
        }

        return ProviderConfig(
            id: id,
            displayName: id.displayName,
            type: type,
            isEnabled: false,
            priority: priority,
            endpoint: endpoint,
            apiKeyRef: id.rawValue,
            appID: nil,
            secretKey: nil,
            timeout: 30,
            model: model,
            shouldFallbackOnAuthFailure: true
        )
    }
}

struct TranslationRequest: Codable, Equatable {
    var text: String
    var sourceLanguage: String?
    var targetLanguage: String
}

struct TranslationResponse: Codable, Equatable {
    var translatedText: String
    var providerID: TranslationProviderID
    var detectedSourceLanguage: String?
}

enum TranslationHistoryMode: String, Codable, Equatable {
    case selectedText
    case ocr
    case ocrTranslate
    case input

    var displayName: String {
        switch self {
        case .selectedText:
            "划词翻译"
        case .ocr:
            "截图 OCR"
        case .ocrTranslate:
            "截图翻译"
        case .input:
            "输入翻译"
        }
    }
}

struct TranslationHistoryItem: Identifiable, Codable, Equatable {
    var id: UUID
    var sourceText: String
    var translatedText: String
    var providerID: TranslationProviderID
    var sourceLanguage: String?
    var targetLanguage: String
    var createdAt: Date
    var mode: TranslationHistoryMode

    init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String,
        providerID: TranslationProviderID,
        sourceLanguage: String?,
        targetLanguage: String,
        createdAt: Date,
        mode: TranslationHistoryMode = .selectedText
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.providerID = providerID
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.createdAt = createdAt
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceText
        case translatedText
        case providerID
        case sourceLanguage
        case targetLanguage
        case createdAt
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceText = try container.decode(String.self, forKey: .sourceText)
        translatedText = try container.decode(String.self, forKey: .translatedText)
        providerID = try container.decode(TranslationProviderID.self, forKey: .providerID)
        sourceLanguage = try container.decodeIfPresent(String.self, forKey: .sourceLanguage)
        targetLanguage = try container.decode(String.self, forKey: .targetLanguage)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        mode = try container.decodeIfPresent(TranslationHistoryMode.self, forKey: .mode) ?? .selectedText
    }
}

struct FavoriteItem: Identifiable, Codable, Equatable {
    var id: UUID
    var historyItem: TranslationHistoryItem
    var createdAt: Date

    init(
        id: UUID = UUID(),
        historyItem: TranslationHistoryItem,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.historyItem = historyItem
        self.createdAt = createdAt
    }
}

struct AppConfiguration: Codable, Equatable {
    var providerID: TranslationProviderID
    var openAICompatibleEndpoint: URL
    var openAICompatibleModel: String
    var targetLanguage: String
    var providerConfigs: [ProviderConfig]
    var defaultProviderID: TranslationProviderID
    var defaultTranslationMode: TranslationMode

    static let `default` = AppConfiguration(
        providerID: .myMemory,
        openAICompatibleEndpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
        openAICompatibleModel: "gpt-4o-mini",
        targetLanguage: "zh-CN",
        providerConfigs: [.openAICompatibleDefault, .myMemoryDefault],
        defaultProviderID: .myMemory,
        defaultTranslationMode: .accurate
    )

    private enum CodingKeys: String, CodingKey {
        case providerID
        case openAICompatibleEndpoint
        case openAICompatibleModel
        case targetLanguage
        case providerConfigs
        case defaultProviderID
        case defaultTranslationMode
    }

    init(
        providerID: TranslationProviderID,
        openAICompatibleEndpoint: URL,
        openAICompatibleModel: String,
        targetLanguage: String,
        providerConfigs: [ProviderConfig],
        defaultProviderID: TranslationProviderID,
        defaultTranslationMode: TranslationMode
    ) {
        self.providerID = providerID
        self.openAICompatibleEndpoint = openAICompatibleEndpoint
        self.openAICompatibleModel = openAICompatibleModel
        self.targetLanguage = targetLanguage
        self.providerConfigs = providerConfigs
        self.defaultProviderID = defaultProviderID
        self.defaultTranslationMode = defaultTranslationMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(TranslationProviderID.self, forKey: .providerID) ?? AppConfiguration.default.providerID
        openAICompatibleEndpoint = try container.decodeIfPresent(URL.self, forKey: .openAICompatibleEndpoint) ?? AppConfiguration.default.openAICompatibleEndpoint
        openAICompatibleModel = try container.decodeIfPresent(String.self, forKey: .openAICompatibleModel) ?? AppConfiguration.default.openAICompatibleModel
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? AppConfiguration.default.targetLanguage
        defaultProviderID = try container.decodeIfPresent(TranslationProviderID.self, forKey: .defaultProviderID) ?? providerID
        defaultTranslationMode = try container.decodeIfPresent(TranslationMode.self, forKey: .defaultTranslationMode) ?? .accurate

        let decodedConfigs = try container.decodeIfPresent([ProviderConfig].self, forKey: .providerConfigs) ?? []
        providerConfigs = AppConfiguration.normalizedConfigs(
            decodedConfigs,
            providerID: providerID,
            endpoint: openAICompatibleEndpoint,
            model: openAICompatibleModel
        )
    }

    static func normalizedConfigs(
        _ configs: [ProviderConfig],
        providerID: TranslationProviderID,
        endpoint: URL,
        model: String
    ) -> [ProviderConfig] {
        var next = configs

        if !next.contains(where: { $0.id == .openAICompatible }) {
            var openAI = ProviderConfig.openAICompatibleDefault
            openAI.endpoint = endpoint
            openAI.model = model
            openAI.isEnabled = providerID == .openAICompatible
            next.append(openAI)
        }

        if !next.contains(where: { $0.id == .myMemory }) {
            var myMemory = ProviderConfig.myMemoryDefault
            myMemory.isEnabled = providerID == .myMemory
            next.append(myMemory)
        }

        let placeholders: [ProviderConfig] = [
            .placeholder(id: .deepL, type: .deepL, priority: 30),
            .placeholder(id: .google, type: .google, priority: 40),
            .placeholder(id: .bing, type: .bing, priority: 50),
            .placeholder(id: .baidu, type: .baidu, priority: 60),
            .placeholder(id: .tencent, type: .tencent, priority: 70),
            .placeholder(id: .volcengine, type: .volcengine, priority: 80),
            .placeholder(id: .glm4Flash, type: .glm4Flash, priority: 90),
            .placeholder(id: .siliconFlow, type: .siliconFlow, priority: 100)
        ]

        for placeholder in placeholders where !next.contains(where: { $0.id == placeholder.id }) {
            next.append(placeholder)
        }

        return next.sorted { $0.priority < $1.priority }
    }
}
