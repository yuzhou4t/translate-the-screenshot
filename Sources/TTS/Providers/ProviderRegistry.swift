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

    var allDescriptors: [ProviderDescriptor] {
        descriptors.values.sorted { $0.displayName < $1.displayName }
    }

    var enabledProviderConfigs: [ProviderConfig] {
        configStore.enabledProviderConfigs
    }

    var defaultProviderConfig: ProviderConfig? {
        configStore.providerConfig(for: configStore.defaultProviderID)
    }

    func register(_ descriptor: ProviderDescriptor) {
        descriptors[descriptor.id] = descriptor
    }

    func descriptor(for id: TranslationProviderID) -> ProviderDescriptor? {
        descriptors[id]
    }

    func setEnabled(_ isEnabled: Bool, for id: TranslationProviderID) {
        guard var config = configStore.providerConfig(for: id) else {
            return
        }

        config.isEnabled = isEnabled
        configStore.updateProviderConfig(config)
    }

    func setDefaultProvider(_ id: TranslationProviderID) {
        configStore.setDefaultProvider(id)
    }

    func makeDefaultProvider() throws -> any TranslationProvider {
        guard let config = defaultProviderConfig else {
            throw TranslationProviderError.providerMessage("默认翻译服务不存在，请在设置中重新选择。")
        }

        guard config.isEnabled else {
            configStore.setDefaultProvider(config.id)
            guard let repairedConfig = defaultProviderConfig, repairedConfig.isEnabled else {
                throw TranslationProviderError.providerMessage("默认翻译服务未启用。")
            }
            return try makeProvider(config: repairedConfig)
        }

        return try makeProvider(config: config)
    }

    func providerAttempts() -> [ProviderAttempt] {
        let enabled = enabledProviderConfigs
            .filter { descriptor(for: $0.id)?.isImplemented == true }
            .sorted { lhs, rhs in
                if lhs.id == configStore.defaultProviderID {
                    return true
                }
                if rhs.id == configStore.defaultProviderID {
                    return false
                }
                return lhs.priority < rhs.priority
            }

        return enabled.map { config in
            ProviderAttempt(config: config) { [weak self] in
                guard let self else {
                    throw TranslationProviderError.providerMessage("ProviderRegistry 已释放。")
                }
                return try self.makeProvider(config: config)
            }
        }
    }

    func makeProvider(config: ProviderConfig) throws -> any TranslationProvider {
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
                model: config.model ?? "gpt-4o-mini",
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
                region: config.model ?? "ap-guangzhou",
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
                region: config.model ?? "cn-north-1",
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
                region: config.model,
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
                model: config.model ?? "glm-4-flash-250414",
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
                model: config.model ?? "Qwen/Qwen2.5-7B-Instruct",
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
                model: config.model ?? "deepseek-chat",
                apiKey: apiKey,
                timeout: config.timeout
            )
        case .gemini:
            guard let apiKeyRef = config.apiKeyRef,
                  let apiKey = try keychainService.loadAPIKey(account: apiKeyRef),
                  !apiKey.isEmpty else {
                throw TranslationProviderError.missingAPIKey
            }

            guard let endpoint = config.endpoint else {
                throw TranslationProviderError.invalidEndpoint
            }

            return OpenAICompatibleProvider(
                id: .gemini,
                displayName: config.displayName,
                endpoint: endpoint,
                model: config.model ?? "gemini-2.5-flash",
                apiKey: apiKey,
                timeout: config.timeout
            )
        }
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
