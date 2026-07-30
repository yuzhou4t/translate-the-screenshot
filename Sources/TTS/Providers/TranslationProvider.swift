import Foundation

protocol TranslationProvider: Sendable {
    var id: TranslationProviderID { get }
    var displayName: String { get }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse
}

struct IdentifiedTranslationText: Sendable, Equatable {
    var id: String
    var text: String
}

struct IdentifiedTranslationTextResult: Sendable, Equatable {
    var id: String
    var translatedText: String
}

protocol IdentifiedBatchTranslationProvider: TranslationProvider {
    func translateBatch(
        _ items: [IdentifiedTranslationText],
        sourceLanguage: String?,
        targetLanguage: String
    ) async throws -> [IdentifiedTranslationTextResult]
}

protocol PromptCompletionProvider: TranslationProvider {
    func complete(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double
    ) async throws -> String
}

enum TranslationProviderError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case invalidResponse
    case authenticationFailed(String)
    case rateLimited(String)
    case timeout(String)
    case network(String)
    case providerMessage(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "缺少 API Key。请在 tts 设置中填写。"
        case .invalidEndpoint:
            "OpenAI 兼容接口地址无效。"
        case .invalidResponse:
            "翻译服务返回了无法解析的响应。"
        case .authenticationFailed(let message):
            message
        case .rateLimited(let message):
            message
        case .timeout(let message):
            message
        case .network(let message):
            message
        case .providerMessage(let message):
            message
        }
    }
}

@MainActor
final class TranslationProviderFactory {
    private let configurationStore: AppConfigurationStore
    private let providerRegistry: ProviderRegistry

    init(
        configurationStore: AppConfigurationStore,
        providerRegistry: ProviderRegistry
    ) {
        self.configurationStore = configurationStore
        self.providerRegistry = providerRegistry
    }

    var targetLanguage: String {
        configurationStore.targetLanguage
    }

    var sourceLanguage: String? {
        configurationStore.sourceLanguage
    }

    var defaultTranslationMode: TranslationMode {
        configurationStore.defaultTranslationMode
    }

    var defaultProviderID: TranslationProviderID {
        configurationStore.defaultProviderID
    }

    var fallbackEnabled: Bool {
        configurationStore.fallbackEnabled
    }

    var fallbackModel: String? {
        configurationStore.fallbackModel
    }

    func supportsTranslationModePrompts(providerID: TranslationProviderID) -> Bool {
        providerID.supportsTranslationModePrompts
    }

    func defaultProviderConfig() -> ProviderConfig? {
        providerRegistry.defaultProviderConfig
    }

    func fallbackProviderConfig() -> ProviderConfig? {
        guard let id = configurationStore.fallbackProviderID,
              let config = providerRegistry.providerConfig(for: id),
              config.isEnabled else {
            return nil
        }
        return config
    }

    func makeProvider(config: ProviderConfig, modelOverride: String? = nil) throws -> any TranslationProvider {
        try providerRegistry.makeProvider(config: config, modelOverride: modelOverride)
    }

}
