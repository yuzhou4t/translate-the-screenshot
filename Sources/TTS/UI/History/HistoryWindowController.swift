import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController {
    private let historyStore: HistoryStore
    private let favoriteStore: FavoriteStore
    private var window: NSWindow?

    init(historyStore: HistoryStore, favoriteStore: FavoriteStore) {
        self.historyStore = historyStore
        self.favoriteStore = favoriteStore
    }

    func show() {
        if window == nil {
            let viewModel = HistoryViewModel(
                historyStore: historyStore,
                favoriteStore: favoriteStore
            )
            let hostingController = NSHostingController(
                rootView: HistoryView(viewModel: viewModel)
                    .preferredColorScheme(.light)
            )
            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = "TTS 历史记录"
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
