import Foundation

struct ModelSuggestion: Identifiable, Hashable {
    var value: String
    var label: String

    var id: String { "\(value)|\(label)" }

    init(_ value: String, label: String? = nil) {
        self.value = value
        self.label = label ?? value
    }
}

enum TranslationScenario: String, Codable, CaseIterable, Identifiable, Equatable {
    case selection
    case input
    case screenshot
    case ocrCleanup
    case imageOverlay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .selection:
            "划词翻译"
        case .input:
            "输入翻译"
        case .screenshot:
            "截图翻译"
        case .ocrCleanup:
            "OCR AI 修复"
        case .imageOverlay:
            "截图覆盖翻译"
        }
    }

    var description: String {
        switch self {
        case .selection:
            "用于划词后的快速理解与短文本翻译。"
        case .input:
            "用于手动输入文本后的常规翻译。"
        case .screenshot:
            "用于截图 OCR 后的正文翻译。"
        case .ocrCleanup:
            "用于 OCR 文本的 AI 修复，不做目标语言翻译。"
        case .imageOverlay:
            "用于截图覆盖翻译，强调短小、紧凑和适合回填原图区域。"
        }
    }

    var defaultTranslationMode: TranslationMode {
        switch self {
        case .selection:
            .accurate
        case .input:
            .natural
        case .screenshot:
            .accurate
        case .ocrCleanup:
            .ocrCleanup
        case .imageOverlay:
            .imageOverlay
        }
    }
}

struct SimpleScenarioTranslationConfig: Codable, Equatable, Identifiable {
    var scenario: TranslationScenario
    var useGlobalDefault: Bool
    var providerID: String
    var modelName: String
    var fallbackEnabled: Bool
    var fallbackProviderID: String
    var fallbackModelName: String

    var id: TranslationScenario { scenario }
}

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
    case deepSeek = "deepseek"
    case gemini = "gemini"
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
            "智谱 GLM"
        case .siliconFlow:
            "硅基流动"
        case .deepSeek:
            "DeepSeek"
        case .gemini:
            "Gemini"
        case .localOCR:
            "本地 OCR"
        }
    }

    var isTranslationProvider: Bool {
        switch self {
        case .openAICompatible, .myMemory, .deepL, .google, .bing, .baidu, .tencent, .volcengine, .glm4Flash, .siliconFlow, .deepSeek, .gemini:
            true
        case .localOCR:
            false
        }
    }

    var supportsTranslationModePrompts: Bool {
        switch self {
        case .openAICompatible, .glm4Flash, .siliconFlow, .deepSeek, .gemini:
            true
        case .myMemory, .deepL, .google, .bing, .baidu, .tencent, .volcengine, .localOCR:
            false
        }
    }

    var suggestedModels: [ModelSuggestion] {
        switch self {
        case .openAICompatible:
            [
                .init("gpt-5.2"),
                .init("gpt-5.2-pro"),
                .init("gpt-5"),
                .init("gpt-5-mini"),
                .init("gpt-5-nano"),
                .init("gpt-4.1"),
                .init("gpt-4.1-mini"),
                .init("gpt-4o"),
                .init("gpt-4o-mini"),
                .init("o4-mini")
            ]
        case .glm4Flash:
            [
                .init("glm-4.7"),
                .init("glm-4.7-flash"),
                .init("glm-4.7-flashx"),
                .init("glm-4.6"),
                .init("glm-4.5"),
                .init("glm-4.5-air"),
                .init("glm-4.5-x"),
                .init("glm-4.5-flash"),
                .init("glm-z1-flash"),
                .init("glm-z1-air"),
                .init("glm-z1-airx"),
                .init("glm-z1-flashx")
            ]
        case .siliconFlow:
            [
                .init("deepseek-ai/DeepSeek-V3.2"),
                .init("Pro/deepseek-ai/DeepSeek-V3.2"),
                .init("deepseek-ai/DeepSeek-V3.1-Terminus"),
                .init("deepseek-ai/DeepSeek-R1"),
                .init("Pro/deepseek-ai/DeepSeek-R1"),
                .init("moonshotai/Kimi-K2-Instruct-0905"),
                .init("Pro/moonshotai/Kimi-K2-Instruct-0905"),
                .init("Qwen/Qwen3.5-397B-A17B"),
                .init("Qwen/Qwen2.5-32B-Instruct"),
                .init("Qwen/Qwen2.5-14B-Instruct"),
                .init("Qwen/Qwen2.5-7B-Instruct")
            ]
        case .deepSeek:
            [
                .init("deepseek-v4-flash", label: "deepseek-v4-flash / DeepSeek-V4-Flash"),
                .init("deepseek-v4-pro", label: "deepseek-v4-pro / DeepSeek-V4-Pro"),
                .init("deepseek-chat", label: "deepseek-chat / 兼容别名（当前对应 V4-Flash 非思考）"),
                .init("deepseek-reasoner", label: "deepseek-reasoner / 兼容别名（当前对应 V4-Flash 思考）")
            ]
        case .gemini:
            [
                .init("gemini-2.5-pro"),
                .init("gemini-2.5-flash"),
                .init("gemini-2.5-flash-lite"),
                .init("gemini-2.5-flash-preview-09-2025"),
                .init("gemini-2.5-flash-lite-preview-09-2025")
            ]
        case .myMemory, .deepL, .google, .bing, .baidu, .tencent, .volcengine, .localOCR:
            []
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
    case deepSeek
    case gemini

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
            "智谱 GLM"
        case .siliconFlow:
            "硅基流动"
        case .deepSeek:
            "DeepSeek"
        case .gemini:
            "Gemini"
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
        case .deepSeek:
            endpoint = URL(string: "https://api.deepseek.com/chat/completions")
            model = "deepseek-v4-flash"
        case .gemini:
            endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
            model = "gemini-2.5-flash"
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
    var translationMode: TranslationMode
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
    var translationMode: TranslationMode

    init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String,
        providerID: TranslationProviderID,
        sourceLanguage: String?,
        targetLanguage: String,
        createdAt: Date,
        mode: TranslationHistoryMode = .selectedText,
        translationMode: TranslationMode = .accurate
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.providerID = providerID
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.createdAt = createdAt
        self.mode = mode
        self.translationMode = translationMode
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
        case translationMode
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
        translationMode = try container.decodeIfPresent(TranslationMode.self, forKey: .translationMode) ?? .accurate
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
    var translationDirection: TranslationDirection
    var providerConfigs: [ProviderConfig]
    var defaultProviderID: TranslationProviderID
    var fallbackEnabled: Bool
    var fallbackProviderID: TranslationProviderID?
    var fallbackModel: String?
    var defaultTranslationMode: TranslationMode
    var scenarioTranslationConfigs: [SimpleScenarioTranslationConfig]

    static let `default` = AppConfiguration(
        providerID: .myMemory,
        openAICompatibleEndpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
        openAICompatibleModel: "gpt-4o-mini",
        targetLanguage: "zh-CN",
        translationDirection: .autoToChinese,
        providerConfigs: [.openAICompatibleDefault, .myMemoryDefault],
        defaultProviderID: .myMemory,
        fallbackEnabled: false,
        fallbackProviderID: nil,
        fallbackModel: nil,
        defaultTranslationMode: .accurate,
        scenarioTranslationConfigs: defaultScenarioConfigs(
            defaultProviderID: .myMemory,
            providerConfigs: [.openAICompatibleDefault, .myMemoryDefault],
            openAICompatibleModel: "gpt-4o-mini"
        )
    )

    private enum CodingKeys: String, CodingKey {
        case providerID
        case openAICompatibleEndpoint
        case openAICompatibleModel
        case targetLanguage
        case translationDirection
        case providerConfigs
        case defaultProviderID
        case fallbackEnabled
        case fallbackProviderID
        case fallbackModel
        case defaultTranslationMode
        case scenarioTranslationConfigs
    }

    init(
        providerID: TranslationProviderID,
        openAICompatibleEndpoint: URL,
        openAICompatibleModel: String,
        targetLanguage: String,
        translationDirection: TranslationDirection,
        providerConfigs: [ProviderConfig],
        defaultProviderID: TranslationProviderID,
        fallbackEnabled: Bool,
        fallbackProviderID: TranslationProviderID?,
        fallbackModel: String?,
        defaultTranslationMode: TranslationMode,
        scenarioTranslationConfigs: [SimpleScenarioTranslationConfig]
    ) {
        self.providerID = providerID
        self.openAICompatibleEndpoint = openAICompatibleEndpoint
        self.openAICompatibleModel = openAICompatibleModel
        self.targetLanguage = targetLanguage
        self.translationDirection = translationDirection
        self.providerConfigs = providerConfigs
        self.defaultProviderID = defaultProviderID
        self.fallbackEnabled = fallbackEnabled
        self.fallbackProviderID = fallbackProviderID
        self.fallbackModel = fallbackModel
        self.defaultTranslationMode = defaultTranslationMode
        self.scenarioTranslationConfigs = scenarioTranslationConfigs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(TranslationProviderID.self, forKey: .providerID) ?? AppConfiguration.default.providerID
        openAICompatibleEndpoint = try container.decodeIfPresent(URL.self, forKey: .openAICompatibleEndpoint) ?? AppConfiguration.default.openAICompatibleEndpoint
        openAICompatibleModel = try container.decodeIfPresent(String.self, forKey: .openAICompatibleModel) ?? AppConfiguration.default.openAICompatibleModel
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? AppConfiguration.default.targetLanguage
        translationDirection = try container.decodeIfPresent(TranslationDirection.self, forKey: .translationDirection) ??
            TranslationDirection.inferred(from: targetLanguage)
        defaultProviderID = try container.decodeIfPresent(TranslationProviderID.self, forKey: .defaultProviderID) ?? providerID
        fallbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .fallbackEnabled) ?? false
        fallbackProviderID = try container.decodeIfPresent(TranslationProviderID.self, forKey: .fallbackProviderID)
        fallbackModel = try container.decodeIfPresent(String.self, forKey: .fallbackModel)
        defaultTranslationMode = try container.decodeIfPresent(TranslationMode.self, forKey: .defaultTranslationMode) ?? .accurate

        let decodedConfigs = try container.decodeIfPresent([ProviderConfig].self, forKey: .providerConfigs) ?? []
        providerConfigs = AppConfiguration.normalizedConfigs(
            decodedConfigs,
            providerID: providerID,
            endpoint: openAICompatibleEndpoint,
            model: openAICompatibleModel
        )
        let decodedScenarioConfigs = try container.decodeIfPresent(
            [SimpleScenarioTranslationConfig].self,
            forKey: .scenarioTranslationConfigs
        ) ?? []
        scenarioTranslationConfigs = AppConfiguration.normalizedScenarioConfigs(
            decodedScenarioConfigs,
            defaultProviderID: defaultProviderID,
            providerConfigs: providerConfigs,
            openAICompatibleModel: openAICompatibleModel
        )

        if fallbackProviderID == defaultProviderID {
            fallbackProviderID = nil
            fallbackModel = nil
        }
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
            .placeholder(id: .siliconFlow, type: .siliconFlow, priority: 100),
            .placeholder(id: .deepSeek, type: .deepSeek, priority: 110),
            .placeholder(id: .gemini, type: .gemini, priority: 120)
        ]

        for placeholder in placeholders where !next.contains(where: { $0.id == placeholder.id }) {
            next.append(placeholder)
        }

        for index in next.indices {
            next[index].displayName = next[index].id.displayName
        }

        return next.sorted { $0.priority < $1.priority }
    }

    static func defaultScenarioConfigs(
        defaultProviderID: TranslationProviderID,
        providerConfigs: [ProviderConfig],
        openAICompatibleModel: String
    ) -> [SimpleScenarioTranslationConfig] {
        normalizedScenarioConfigs(
            [],
            defaultProviderID: defaultProviderID,
            providerConfigs: providerConfigs,
            openAICompatibleModel: openAICompatibleModel
        )
    }

    static func normalizedScenarioConfigs(
        _ configs: [SimpleScenarioTranslationConfig],
        defaultProviderID: TranslationProviderID,
        providerConfigs: [ProviderConfig],
        openAICompatibleModel: String
    ) -> [SimpleScenarioTranslationConfig] {
        let globalProviderID = defaultProviderID.rawValue
        let globalModelName = globalModelName(
            defaultProviderID: defaultProviderID,
            providerConfigs: providerConfigs,
            openAICompatibleModel: openAICompatibleModel
        )

        return TranslationScenario.allCases.map { scenario in
            let existing = configs.first { $0.scenario == scenario }
            let useGlobalDefault = existing?.useGlobalDefault ?? true

            return SimpleScenarioTranslationConfig(
                scenario: scenario,
                useGlobalDefault: useGlobalDefault,
                providerID: useGlobalDefault ? globalProviderID : (existing?.providerID ?? globalProviderID),
                modelName: useGlobalDefault ? globalModelName : (existing?.modelName ?? globalModelName),
                fallbackEnabled: existing?.fallbackEnabled ?? false,
                fallbackProviderID: existing?.fallbackProviderID ?? "",
                fallbackModelName: existing?.fallbackModelName ?? ""
            )
        }
    }

    private static func globalModelName(
        defaultProviderID: TranslationProviderID,
        providerConfigs: [ProviderConfig],
        openAICompatibleModel: String
    ) -> String {
        if defaultProviderID == .openAICompatible {
            return openAICompatibleModel
        }

        return providerConfigs.first(where: { $0.id == defaultProviderID })?.model ?? ""
    }
}
