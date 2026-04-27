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
    let ocrTextBlockGrouper = OCRTextBlockGrouper()
    let toastPanel = ToastPanel()
    let screenshotOverlayRenderer = ScreenshotTranslationOverlayRenderer()
    lazy var translatedImagePreviewWindowController = TranslatedImagePreviewWindowController(
        renderer: screenshotOverlayRenderer
    )

    lazy var floatingPanel = FloatingTranslatePanel(
        favoriteStore: favoriteStore,
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
        ocrTextBlockGrouper: ocrTextBlockGrouper,
        ocrResultPanel: ocrResultPanel,
        translationService: translationService,
        historyStore: historyStore,
        floatingPanel: floatingPanel,
        toastPanel: toastPanel,
        translatedImagePreviewWindowController: translatedImagePreviewWindowController
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
