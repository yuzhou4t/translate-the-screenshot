import AppKit
import Foundation

@MainActor
final class AppServices {
    static let shared = AppServices()

    let configurationStore = AppConfigurationStore()
    let keychainService = KeychainService()
    let clipboardManager = ClipboardManager()
    let permissionManager = PermissionManager()
    let ocrService = OCRService()
    let toastPanel = ToastPanel()
    let screenshotClipboardToastPanel = ToastPanel(
        level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    )
    let volcengineImageTranslationPolicyStore = VolcengineImageTranslationPolicyStore()
    let aiUsageSettingsStore = AIUsageSettingsStore()
    let aiUsageTokenStore = AIUsageTokenStore()
    let screenshotOverlayRenderer = ScreenshotTranslationOverlayRenderer()
    lazy var screenRecordingController: ScreenRecordingController = {
        let controller = ScreenRecordingController(
            permissionManager: permissionManager,
            toastPanel: toastPanel
        )
        controller.canBeginSelection = { [weak self] in
            !(self?.screenshotCaptureController.isCaptureInteractionActive ?? true)
        }
        return controller
    }()
    lazy var aiUsageProviderRegistry = AIUsageProviderRegistry(
        settingsStore: aiUsageSettingsStore,
        keychainService: keychainService,
        configurationStore: configurationStore
    )
    lazy var aiUsageStore = AIUsageStore(
        settingsStore: aiUsageSettingsStore,
        providerRegistry: aiUsageProviderRegistry
    )
    lazy var codexAccountSwitcherStore = CodexAccountSwitcherStore(
        onWillSwitch: { [weak self] in
            guard let self else { return }
            await self.providerRegistry.resetCodexSubscriptionSession()
        },
        onDidSwitch: { [weak self] in
            self?.aiUsageStore.refreshNow()
        }
    )
    lazy var imageOverlayTranslationWindowController = ImageOverlayTranslationWindowController(
        renderer: screenshotOverlayRenderer,
        translationService: translationService,
        debugWriter: OverlayPipelineDebugWriter(),
        providerRegistry: providerRegistry,
        configurationStore: configurationStore,
        policyStore: volcengineImageTranslationPolicyStore,
        openVolcengineSettings: { [weak self] in
            self?.settingsWindowController.show(
                tab: .translationService,
                providerID: .volcengine
            )
        }
    )

    lazy var floatingPanel = FloatingTranslatePanel(
        translationService: translationService
    )

    lazy var ocrResultPanel = OCRResultPanel(
        translationService: translationService,
        providerFactory: providerFactory,
        floatingPanel: floatingPanel
    )

    lazy var settingsWindowController = SettingsWindowController(
        configurationStore: configurationStore,
        keychainService: keychainService,
        providerRegistry: providerRegistry,
        policyStore: volcengineImageTranslationPolicyStore,
        permissionManager: permissionManager,
        aiUsageSettingsStore: aiUsageSettingsStore,
        aiUsageProviderRegistry: aiUsageProviderRegistry,
        aiUsageStore: aiUsageStore
    )

    lazy var selectionReader = SelectionReader(
        clipboardManager: clipboardManager,
        permissionManager: permissionManager
    )

    lazy var providerFactory = TranslationProviderFactory(
        configurationStore: configurationStore,
        providerRegistry: providerRegistry
    )

    lazy var providerRegistry = ProviderRegistry(
        configStore: configurationStore,
        keychainService: keychainService
    )

    lazy var translationService = TranslationService(
        providerFactory: providerFactory
    )

    lazy var inputTranslateWindowController = InputTranslateWindowController(
        translationService: translationService
    )

    lazy var screenshotCaptureController = ScreenshotCaptureController(
        permissionManager: permissionManager,
        ocrService: ocrService,
        ocrResultPanel: ocrResultPanel,
        translationService: translationService,
        floatingPanel: floatingPanel,
        toastPanel: toastPanel,
        clipboardToastPanel: screenshotClipboardToastPanel,
        imageOverlayTranslationWindowController: imageOverlayTranslationWindowController,
        providerRegistry: providerRegistry,
        policyStore: volcengineImageTranslationPolicyStore,
        settingsWindowController: settingsWindowController,
        canBeginCapture: { [weak self] in
            !(self?.screenRecordingController.isBlockingOtherCapture ?? true)
        }
    )

    lazy var translationController = SelectionTranslationController(
        selectionReader: selectionReader,
        translationService: translationService,
        floatingPanel: floatingPanel
    )

    lazy var hotkeyManager = HotkeyManager(
        translationController: translationController,
        inputTranslateWindowController: inputTranslateWindowController,
        screenshotCaptureController: screenshotCaptureController,
        screenRecordingController: screenRecordingController
    )

    private init() {}
}
