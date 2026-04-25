import AppKit
import SwiftUI

@MainActor
final class FavoritesWindowController {
    private let favoriteStore: FavoriteStore
    private var window: NSWindow?

    init(favoriteStore: FavoriteStore) {
        self.favoriteStore = favoriteStore
    }

    func show() {
        if window == nil {
            let viewModel = FavoritesViewModel(favoriteStore: favoriteStore)
            let hostingController = NSHostingController(
                rootView: FavoritesView(viewModel: viewModel)
                    .preferredColorScheme(.light)
            )
            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = "TTS 收藏夹"
            newWindow.appearance = NSAppearance(named: .aqua)
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.setContentSize(NSSize(width: 860, height: 560))
            newWindow.center()
            newWindow.isReleasedWhenClosed = false
            window = newWindow
        }

        window?.makeKeyAndOrderFront(nil)
    }
}
