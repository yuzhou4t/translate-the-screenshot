import Foundation

struct ProviderDescriptor: Identifiable, Equatable {
    var id: TranslationProviderID
    var displayName: String
    var type: TranslationProviderType
    var isImplemented: Bool
}

@MainActor
final class ProviderRegistry {
    private var descriptors: [TranslationProviderID: ProviderDescriptor] = [:]
    private let configStore: ProviderConfigStore
    private let keychainService: KeychainService

    init(configStore: ProviderConfigStore, keychainService: KeychainService) {
        self.configStore = configStore
        self.keychainService = keychainService
        registerBuiltInProviders()
    }

    var defaultProviderConfig: ProviderConfig? {
        configStore.providerConfig(for: configStore.defaultProviderID)
    }

    func providerConfig(for id: TranslationProviderID) -> ProviderConfig? {
        configStore.providerConfig(for: id)
    }

    func register(_ descriptor: ProviderDescriptor) {
        descriptors[descriptor.id] = descriptor
    }

    func descriptor(for id: TranslationProviderID) -> ProviderDescriptor? {
        descriptors[id]
    }

    func makeProvider(config: ProviderConfig, modelOverride: String? = nil) throws -> any TranslationProvider {
        guard descriptor(for: config.id)?.isImplemented == true else {
            throw TranslationProviderError.providerMessage("\(config.displayName) 尚未接入。")
        }

        switch config.type {
        case .openAICompatible:
            guard let apiKeyRef = config.apiKeyRef,
                  let apiKey = try keychainService.loadAPIKey(account: apiKeyRef),
                  !apiKey.isEmpty else {
                throw TranslationProviderError.missingAPIKey
            }

            guard let endpoint = config.endpoint else {
                throw TranslationProviderError.invalidEndpoint
            }

            return OpenAICompatibleProvider(
                endpoint: endpoint,
                model: modelOverride ?? config.model ?? "gpt-4o-mini",
                apiKey: apiKey,
                timeout: config.timeout
            )
        case .myMemory:
            return MyMemoryProvider()
        case .deepL:
            guard let apiKeyRef = config.apiKeyRef,
                  let apiKey = try keychainService.loadAPIKey(account: apiKeyRef),
                  !apiKey.isEmpty else {
                throw TranslationProviderError.missingAPIKey
            }

            guard let endpoint = config.endpoint else {
                throw TranslationProviderError.invalidEndpoint
            }

            return DeepLProvider(
                endpoint: endpoint,
                apiKey: apiKey,
                timeout: config.timeout
            )
        case .google:
            guard let apiKeyRef = config.apiKeyRef,
                  let apiKey = try keychainService.loadAPIKey(account: apiKeyRef),
                  !apiKey.isEmpty else {
                throw TranslationProviderError.missingAPIKey
            }

            guard let endpoint = config.endpoint else {
                throw TranslationProviderError.invalidEndpoint
            }

            return GoogleTranslateProvider(
                endpoint: endpoint,
                apiKey: apiKey,
                timeout: config.timeout
            )
        case .tencent:
            let secretKeyAccount = secretKeyAccount(for: config.id)
            guard let secretID = config.appID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !secretID.isEmpty,
                  let secretKey = try keychainService.loadAPIKey(account: secretKeyAccount),
                  !secretKey.isEmpty else {
                throw TranslationProviderError.missingAPIKey
            }

            guard let endpoint = config.endpoint else {
                throw TranslationProviderError.invalidEndpoint
            }

            return TencentTranslateProvider(
                endpoint: endpoint,
                secretID: secretID,
                secretKey: secretKey,
                region: modelOverride ?? config.model ?? "ap-guangzhou",
                timeout: config.timeout
            )
        case .volcengine:
            let secretKeyAccount = secretKeyAccount(for: config.id)
            guard let accessKeyID = config.appID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accessKeyID.isEmpty,
                  let secretAccessKey = try keychainService.loadAPIKey(account: secretKeyAccount),
                  !secretAccessKey.isEmpty else {
                throw TranslationProviderError.missingAPIKey
            }

            guard let endpoint = config.endpoint else {
                throw TranslationProviderError.invalidEndpoint
            }

            return VolcengineTranslateProvider(
                endpoint: endpoint,
                accessKeyID: accessKeyID,
                secretAccessKey: secretAccessKey,
                region: modelOverride ?? config.model ?? "cn-north-1",
                timeout: config.timeout
            )
        case .bing:
            guard let apiKeyRef = config.apiKeyRef,
                  let apiKey = try keychainService.loadAPIKey(account: apiKeyRef),
                  !apiKey.isEmpty else {
                throw TranslationProviderError.missingAPIKey
            }

            guard let endpoint = config.endpoint else {
                throw TranslationProviderError.invalidEndpoint
            }

            return BingTranslateProvider(
                endpoint: endpoint,
                apiKey: apiKey,
                region: modelOverride ?? config.model,
                timeout: config.timeout
            )
        case .baidu:
            let secretKeyAccount = secretKeyAccount(for: config.id)
            guard let appID = config.appID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !appID.isEmpty,
                  let secretKey = try keychainService.loadAPIKey(account: secretKeyAccount),
                  !secretKey.isEmpty else {
                throw TranslationProviderError.missingAPIKey
            }

            guard let endpoint = config.endpoint else {
                throw TranslationProviderError.invalidEndpoint
            }

            return BaiduTranslateProvider(
                endpoint: endpoint,
                appID: appID,
                secretKey: secretKey,
                timeout: config.timeout
            )
        case .glm4Flash:
            guard let apiKeyRef = config.apiKeyRef,
                  let apiKey = try keychainService.loadAPIKey(account: apiKeyRef),
                  !apiKey.isEmpty else {
                throw TranslationProviderError.missingAPIKey
            }

            guard let endpoint = config.endpoint else {
                throw TranslationProviderError.invalidEndpoint
            }

            return OpenAICompatibleProvider(
                id: .glm4Flash,
                displayName: config.displayName,
                endpoint: endpoint,
                model: modelOverride ?? config.model ?? "glm-4-flash-250414",
                apiKey: apiKey,
                timeout: config.timeout
            )
        case .siliconFlow:
            guard let apiKeyRef = config.apiKeyRef,
                  let apiKey = try keychainService.loadAPIKey(account: apiKeyRef),
                  !apiKey.isEmpty else {
                throw TranslationProviderError.missingAPIKey
            }

            guard let endpoint = config.endpoint else {
                throw TranslationProviderError.invalidEndpoint
            }

            return OpenAICompatibleProvider(
                id: .siliconFlow,
                displayName: config.displayName,
                endpoint: endpoint,
                model: modelOverride ?? config.model ?? "Qwen/Qwen2.5-7B-Instruct",
                apiKey: apiKey,
                timeout: config.timeout
            )
        case .deepSeek:
            guard let apiKeyRef = config.apiKeyRef,
                  let apiKey = try keychainService.loadAPIKey(account: apiKeyRef),
                  !apiKey.isEmpty else {
                throw TranslationProviderError.missingAPIKey
            }

            guard let endpoint = config.endpoint else {
                throw TranslationProviderError.invalidEndpoint
            }

            return OpenAICompatibleProvider(
                id: .deepSeek,
                displayName: config.displayName,
                endpoint: endpoint,
                model: modelOverride ?? config.model ?? "deepseek-chat",
                apiKey: apiKey,
                timeout: config.timeout
            )
        case .gemini:
            guard let apiKeyRef = config.apiKeyRef,
                  let apiKey = try keychainService.loadAPIKey(account: apiKeyRef),
                  !apiKey.isEmpty else {
                throw TranslationProviderError.missingAPIKey
            }

            return GeminiProvider(
                id: .gemini,
                displayName: config.displayName,
                endpoint: config.endpoint,
                model: modelOverride ?? config.model ?? "gemini-2.5-flash",
                apiKey: apiKey,
                timeout: config.timeout
            )
        }
    }

    func makeVolcengineImageTranslationProvider() throws -> VolcengineTranslateProvider {
        guard let config = providerConfig(for: .volcengine) else {
            throw TranslationProviderError.providerMessage("缺少火山翻译配置。")
        }

        let secretKeyAccount = secretKeyAccount(for: .volcengine)
        guard let accessKeyID = config.appID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessKeyID.isEmpty,
              let secretAccessKey = try keychainService.loadAPIKey(account: secretKeyAccount),
              !secretAccessKey.isEmpty else {
            throw TranslationProviderError.providerMessage(
                "请在设置 → 翻译服务 → 火山翻译中填写 AccessKey ID 与 Secret Access Key。"
            )
        }

        return VolcengineTranslateProvider(
            endpoint: URL(string: "https://translate.volcengineapi.com")!,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            region: config.model ?? "cn-north-1",
            timeout: config.timeout
        )
    }

    private func registerBuiltInProviders() {
        register(.init(
            id: .openAICompatible,
            displayName: TranslationProviderID.openAICompatible.displayName,
            type: .openAICompatible,
            isImplemented: true
        ))
        register(.init(
            id: .myMemory,
            displayName: TranslationProviderID.myMemory.displayName,
            type: .myMemory,
            isImplemented: true
        ))
        register(.init(id: .deepL, displayName: TranslationProviderID.deepL.displayName, type: .deepL, isImplemented: true))
        register(.init(id: .google, displayName: TranslationProviderID.google.displayName, type: .google, isImplemented: true))
        register(.init(id: .bing, displayName: TranslationProviderID.bing.displayName, type: .bing, isImplemented: true))
        register(.init(id: .baidu, displayName: TranslationProviderID.baidu.displayName, type: .baidu, isImplemented: true))
        register(.init(id: .tencent, displayName: TranslationProviderID.tencent.displayName, type: .tencent, isImplemented: true))
        register(.init(id: .volcengine, displayName: TranslationProviderID.volcengine.displayName, type: .volcengine, isImplemented: true))
        register(.init(id: .glm4Flash, displayName: TranslationProviderID.glm4Flash.displayName, type: .glm4Flash, isImplemented: true))
        register(.init(id: .siliconFlow, displayName: TranslationProviderID.siliconFlow.displayName, type: .siliconFlow, isImplemented: true))
        register(.init(id: .deepSeek, displayName: TranslationProviderID.deepSeek.displayName, type: .deepSeek, isImplemented: true))
        register(.init(id: .gemini, displayName: TranslationProviderID.gemini.displayName, type: .gemini, isImplemented: true))
    }

    private func secretKeyAccount(for id: TranslationProviderID) -> String {
        "\(id.rawValue).secretKey"
    }
}
