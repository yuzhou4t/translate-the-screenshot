import SwiftUI

@main
struct TTSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                viewModel: SettingsViewModel(
                    configurationStore: AppServices.shared.configurationStore,
                    keychainService: AppServices.shared.keychainService,
                    providerRegistry: AppServices.shared.providerRegistry,
                    policyStore: AppServices.shared.volcengineImageTranslationPolicyStore,
                    permissionManager: AppServices.shared.permissionManager
                ),
                aiUsageViewModel: AIUsageSettingsViewModel(
                    settingsStore: AppServices.shared.aiUsageSettingsStore,
                    providerRegistry: AppServices.shared.aiUsageProviderRegistry,
                    keychainService: AppServices.shared.keychainService,
                    usageStore: AppServices.shared.aiUsageStore
                )
            )
        }
    }
}
