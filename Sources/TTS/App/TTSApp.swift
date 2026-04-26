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
                    providerRegistry: AppServices.shared.providerRegistry
                )
            )
        }
    }
}
