import Foundation

protocol TranslationProvider: Sendable {
    var id: TranslationProviderID { get }
    var displayName: String { get }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse
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

    func makeActiveProvider() throws -> any TranslationProvider {
        try providerRegistry.makeDefaultProvider()
    }

    func providerAttempts() -> [ProviderAttempt] {
        providerRegistry.providerAttempts()
    }
}

struct ProviderAttempt: Identifiable {
    var id: TranslationProviderID { config.id }
    var config: ProviderConfig
    var makeProvider: () throws -> any TranslationProvider
}
