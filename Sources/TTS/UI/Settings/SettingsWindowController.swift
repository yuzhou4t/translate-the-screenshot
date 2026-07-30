import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let configurationStore: AppConfigurationStore
    private let keychainService: KeychainService
    private let providerRegistry: ProviderRegistry
    private let policyStore: VolcengineImageTranslationPolicyStore
    private let permissionManager: PermissionManager
    private var window: NSWindow?
    private var viewModel: SettingsViewModel?

    init(
        configurationStore: AppConfigurationStore,
        keychainService: KeychainService,
        providerRegistry: ProviderRegistry,
        policyStore: VolcengineImageTranslationPolicyStore,
        permissionManager: PermissionManager
    ) {
        self.configurationStore = configurationStore
        self.keychainService = keychainService
        self.providerRegistry = providerRegistry
        self.policyStore = policyStore
        self.permissionManager = permissionManager
    }

    func show(
        tab: SettingsTab? = nil,
        providerID: TranslationProviderID? = nil
    ) {
        if window == nil {
            let viewModel = SettingsViewModel(
                configurationStore: configurationStore,
                keychainService: keychainService,
                providerRegistry: providerRegistry,
                policyStore: policyStore,
                permissionManager: permissionManager
            )
            let hostingController = NSHostingController(
                rootView: SettingsView(viewModel: viewModel)
            )
            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = "TTS 设置"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.setContentSize(NSSize(width: 1000, height: 720))
            newWindow.minSize = NSSize(width: 960, height: 680)
            newWindow.center()
            newWindow.isReleasedWhenClosed = false
            window = newWindow
            self.viewModel = viewModel
        }

        viewModel?.reload()
        if let tab {
            viewModel?.selectedTab = tab
        }
        if let providerID {
            viewModel?.selectProvider(providerID)
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
