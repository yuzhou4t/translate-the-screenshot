@testable import TTS
import Foundation

func checkLegacyConfigurationDecodesAfterSimplification() {
    let legacyJSON = """
    {
      "providerID": "mymemory",
      "defaultProviderID": "mymemory",
      "defaultTranslationMode": "academic",
      "enableVisionSegmentation": true,
      "visionSegmentationConfig": {
        "providerID": "gemini",
        "model": "gemini-2.5-flash"
      },
      "scenarioTranslationConfigs": [
        {
          "scenario": "screenshot",
          "useGlobalDefault": false,
          "providerID": "gemini",
          "modelName": "gemini-2.5-flash",
          "fallbackEnabled": true,
          "fallbackProviderID": "mymemory",
          "fallbackModelName": ""
        }
      ]
    }
    """

    let configuration = try! JSONDecoder().decode(
        AppConfiguration.self,
        from: Data(legacyJSON.utf8)
    )

    precondition(configuration.defaultProviderID == .myMemory)
    precondition(configuration.defaultTranslationMode == .accurate)
    precondition(TranslationMode(rawValue: "academic") == .academic)
    precondition(TranslationMode(rawValue: "imageOverlay") == .imageOverlay)
}

@MainActor
func checkFallbackConfigurationStaysValid() {
    let suiteName = "TTSTests.ConfigurationCompatibility.\(UUID().uuidString)"
    guard let userDefaults = UserDefaults(suiteName: suiteName) else {
        preconditionFailure("could not create isolated UserDefaults")
    }
    defer {
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    let store = ProviderConfigStore(userDefaults: userDefaults)
    store.setFallbackConfiguration(
        enabled: true,
        providerID: .openAICompatible,
        model: "gpt-4o-mini"
    )
    precondition(store.fallbackEnabled)
    precondition(store.fallbackProviderID == .openAICompatible)
    precondition(store.providerConfig(for: .openAICompatible)?.isEnabled == true)

    var disabledFallback = store.providerConfig(for: .openAICompatible)!
    disabledFallback.isEnabled = false
    store.updateProviderConfig(disabledFallback)
    precondition(!store.fallbackEnabled)
    precondition(store.fallbackProviderID == nil)
    precondition(store.fallbackModel == nil)

    store.setFallbackConfiguration(enabled: true, providerID: nil, model: nil)
    precondition(!store.fallbackEnabled)
    precondition(store.fallbackProviderID == nil)

    store.setFallbackConfiguration(enabled: true, providerID: .openAICompatible, model: nil)
    store.setDefaultProvider(.openAICompatible)
    precondition(!store.fallbackEnabled)
    precondition(store.fallbackProviderID == nil)
}
