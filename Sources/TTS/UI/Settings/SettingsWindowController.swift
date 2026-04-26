import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let configurationStore: AppConfigurationStore
    private let keychainService: KeychainService
    private let providerRegistry: ProviderRegistry
    private var window: NSWindow?

    init(
        configurationStore: AppConfigurationStore,
        keychainService: KeychainService,
        providerRegistry: ProviderRegistry
    ) {
        self.configurationStore = configurationStore
        self.keychainService = keychainService
        self.providerRegistry = providerRegistry
    }

    func show() {
        if window == nil {
            let viewModel = SettingsViewModel(
                configurationStore: configurationStore,
                keychainService: keychainService,
                providerRegistry: providerRegistry
            )
            let hostingController = NSHostingController(
                rootView: SettingsView(viewModel: viewModel)
            )
            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = "TTS 设置"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.setContentSize(NSSize(width: 940, height: 660))
            newWindow.minSize = NSSize(width: 900, height: 620)
            newWindow.center()
            newWindow.isReleasedWhenClosed = false
            window = newWindow
        }

        window?.makeKeyAndOrderFront(nil)
    }
}
