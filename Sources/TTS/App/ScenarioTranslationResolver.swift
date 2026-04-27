import Foundation

struct ScenarioTranslationPlan: Equatable {
    var scenario: TranslationScenario
    var primaryProviderID: String
    var primaryModelName: String
    var fallbackEnabled: Bool
    var fallbackProviderID: String
    var fallbackModelName: String
    var usesGlobalDefault: Bool
    var message: String
}

@MainActor
struct ScenarioTranslationResolver {
    func resolve(
        scenario: TranslationScenario,
        configurationStore: AppConfigurationStore,
        globalDefaultProviderID: String,
        globalDefaultModelName: String
    ) -> ScenarioTranslationPlan {
        let globalProviderID = trimmed(globalDefaultProviderID)
        let globalModelName = trimmed(globalDefaultModelName)

        guard let config = configurationStore.scenarioTranslationConfigs.first(where: { $0.scenario == scenario }) else {
            return ScenarioTranslationPlan(
                scenario: scenario,
                primaryProviderID: globalProviderID,
                primaryModelName: globalModelName,
                fallbackEnabled: false,
                fallbackProviderID: "",
                fallbackModelName: "",
                usesGlobalDefault: true,
                message: "\(scenario.displayName) 使用全局默认配置。"
            )
        }

        if config.useGlobalDefault {
            return ScenarioTranslationPlan(
                scenario: scenario,
                primaryProviderID: globalProviderID,
                primaryModelName: globalModelName,
                fallbackEnabled: false,
                fallbackProviderID: "",
                fallbackModelName: "",
                usesGlobalDefault: true,
                message: "\(scenario.displayName) 使用全局默认配置。"
            )
        }

        let scenarioProviderID = trimmed(config.providerID)
        let scenarioModelName = trimmed(config.modelName)
        let hasCompletePrimaryConfig = !scenarioProviderID.isEmpty && !scenarioModelName.isEmpty

        let resolvedPrimaryProviderID = hasCompletePrimaryConfig ? scenarioProviderID : globalProviderID
        let resolvedPrimaryModelName = hasCompletePrimaryConfig ? scenarioModelName : globalModelName

        let fallbackProviderID = trimmed(config.fallbackProviderID)
        let fallbackModelName = trimmed(config.fallbackModelName)
        let fallbackEnabled = config.fallbackEnabled &&
            !fallbackProviderID.isEmpty &&
            !fallbackModelName.isEmpty

        let message: String
        if hasCompletePrimaryConfig {
            message = "\(scenario.displayName) 使用场景自定义配置。"
        } else {
            message = "场景配置不完整，已回退到全局默认配置。"
        }

        return ScenarioTranslationPlan(
            scenario: scenario,
            primaryProviderID: resolvedPrimaryProviderID,
            primaryModelName: resolvedPrimaryModelName,
            fallbackEnabled: fallbackEnabled,
            fallbackProviderID: fallbackEnabled ? fallbackProviderID : "",
            fallbackModelName: fallbackEnabled ? fallbackModelName : "",
            usesGlobalDefault: !hasCompletePrimaryConfig,
            message: message
        )
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
