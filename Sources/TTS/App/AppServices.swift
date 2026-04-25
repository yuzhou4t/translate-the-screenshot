import Foundation

@MainActor
final class AppServices {
    static let shared = AppServices()

    let configurationStore = AppConfigurationStore()
    let keychainService = KeychainService()
    let clipboardManager = ClipboardManager()
    let permissionManager = PermissionManager()
    let historyStore = HistoryStore()
    let favoriteStore = FavoriteStore()
    let ocrService = OCRService()
    let ocrResultPanel = OCRResultPanel()
    let toastPanel = ToastPanel()

    lazy var floatingPanel = FloatingTranslatePanel(favoriteStore: favoriteStore)

    lazy var settingsWindowController = SettingsWindowController(
        configurationStore: configurationStore,
        keychainService: keychainService,
        providerRegistry: providerRegistry
    )

    lazy var historyWindowController = HistoryWindowController(
        historyStore: historyStore,
        favoriteStore: favoriteStore
    )

    lazy var favoritesWindowController = FavoritesWindowController(
        favoriteStore: favoriteStore
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
        providerFactory: providerFactory,
        historyStore: historyStore
    )

    lazy var inputTranslateWindowController = InputTranslateWindowController(
        translationService: translationService,
        favoriteStore: favoriteStore
    )

    lazy var screenshotCaptureController = ScreenshotCaptureController(
        permissionManager: permissionManager,
        ocrService: ocrService,
        ocrResultPanel: ocrResultPanel,
        translationService: translationService,
        historyStore: historyStore,
        floatingPanel: floatingPanel,
        toastPanel: toastPanel
    )

    lazy var translationController = SelectionTranslationController(
        selectionReader: selectionReader,
        translationService: translationService,
        floatingPanel: floatingPanel
    )

    lazy var hotkeyManager = HotkeyManager(
        translationController: translationController,
        inputTranslateWindowController: inputTranslateWindowController,
        screenshotCaptureController: screenshotCaptureController
    )

    private init() {}
}
