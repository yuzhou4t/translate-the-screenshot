import Foundation

@MainActor
final class ProviderConfigStore: ObservableObject {
    @Published private(set) var configuration: AppConfiguration

    private let userDefaults: UserDefaults
    private let key = "appConfiguration"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if let data = userDefaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppConfiguration.self, from: data) {
            configuration = decoded
        } else {
            configuration = .default
        }

        repairDefaultProviderState()
    }

    func update(_ mutate: (inout AppConfiguration) -> Void) {
        var next = configuration
        mutate(&next)
        next.providerConfigs = AppConfiguration.normalizedConfigs(
            next.providerConfigs,
            providerID: next.defaultProviderID,
            endpoint: next.openAICompatibleEndpoint,
            model: next.openAICompatibleModel
        )
        next.providerID = next.defaultProviderID
        configuration = next
        persist()
    }

    var providerConfigs: [ProviderConfig] {
        configuration.providerConfigs.sorted { $0.priority < $1.priority }
    }

    var enabledProviderConfigs: [ProviderConfig] {
        providerConfigs.filter(\.isEnabled)
    }

    var defaultProviderID: TranslationProviderID {
        configuration.defaultProviderID
    }

    var targetLanguage: String {
        configuration.translationDirection.targetLanguage ?? configuration.targetLanguage
    }

    var sourceLanguage: String? {
        configuration.translationDirection.sourceLanguage
    }

    var translationDirection: TranslationDirection {
        configuration.translationDirection
    }

    var defaultTranslationMode: TranslationMode {
        configuration.defaultTranslationMode
    }

    var modelProfiles: [ModelProfile] {
        configuration.modelProfiles.sorted { $0.priority < $1.priority }
    }

    func providerConfig(for id: TranslationProviderID) -> ProviderConfig? {
        configuration.providerConfigs.first { $0.id == id }
    }

    func setTranslationDirection(_ direction: TranslationDirection) {
        update { configuration in
            configuration.translationDirection = direction
            if let targetLanguage = direction.targetLanguage {
                configuration.targetLanguage = targetLanguage
            }
        }
    }

    func setDefaultTranslationMode(_ mode: TranslationMode) {
        update { configuration in
            configuration.defaultTranslationMode = mode
        }
    }

    func updateModelProfile(_ profile: ModelProfile) {
        update { configuration in
            if let index = configuration.modelProfiles.firstIndex(where: { $0.id == profile.id }) {
                configuration.modelProfiles[index] = profile
            } else {
                configuration.modelProfiles.append(profile)
            }
        }
    }

    func setDefaultProvider(_ id: TranslationProviderID) {
        update { configuration in
            configuration.defaultProviderID = id
            configuration.providerID = id
            if let index = configuration.providerConfigs.firstIndex(where: { $0.id == id }) {
                configuration.providerConfigs[index].isEnabled = true
            }
        }
    }

    func updateProviderConfig(_ config: ProviderConfig) {
        update { configuration in
            if let index = configuration.providerConfigs.firstIndex(where: { $0.id == config.id }) {
                configuration.providerConfigs[index] = config
            } else {
                configuration.providerConfigs.append(config)
            }

            if config.id == .openAICompatible {
                configuration.openAICompatibleEndpoint = config.endpoint ?? configuration.openAICompatibleEndpoint
                configuration.openAICompatibleModel = config.model ?? configuration.openAICompatibleModel
            }
        }
    }

    private func repairDefaultProviderState() {
        update { configuration in
            configuration.providerConfigs = AppConfiguration.normalizedConfigs(
                configuration.providerConfigs,
                providerID: configuration.defaultProviderID,
                endpoint: configuration.openAICompatibleEndpoint,
                model: configuration.openAICompatibleModel
            )

            if configuration.modelProfiles.isEmpty {
                configuration.modelProfiles = ModelProfile.defaultProfiles
            }

            if !configuration.providerConfigs.contains(where: { $0.id == configuration.defaultProviderID }) {
                configuration.defaultProviderID = .myMemory
                configuration.providerID = .myMemory
            }

            if let index = configuration.providerConfigs.firstIndex(where: { $0.id == configuration.defaultProviderID }) {
                configuration.providerConfigs[index].isEnabled = true
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(configuration) {
            userDefaults.set(data, forKey: key)
        }
    }
}

typealias AppConfigurationStore = ProviderConfigStore
