import AppKit
import SwiftUI

@MainActor
final class InputTranslateWindowController {
    private let translationService: TranslationService
    private let favoriteStore: FavoriteStore
    private var window: InputTranslatePanel?

    init(translationService: TranslationService, favoriteStore: FavoriteStore) {
        self.translationService = translationService
        self.favoriteStore = favoriteStore
    }

    func show() {
        if window == nil {
            let panel = InputTranslatePanel(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = "输入翻译"
            panel.appearance = NSAppearance(named: .aqua)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.contentViewController = NSHostingController(
                rootView: InputTranslateView(
                    viewModel: InputTranslateViewModel(
                        translationService: self.translationService,
                        favoriteStore: self.favoriteStore
                    ),
                    onClose: { [weak self] in
                        self?.close()
                    }
                )
                .preferredColorScheme(.light)
            )
            panel.center()
            window = panel
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }
}

private final class InputTranslatePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
