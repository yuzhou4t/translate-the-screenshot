import AppKit
import Foundation

@MainActor
final class SelectionTranslationController {
    private let selectionReader: SelectionReader
    private let translationService: TranslationService
    private let floatingPanel: FloatingTranslatePanel
    private var activeTask: Task<Void, Never>?

    init(
        selectionReader: SelectionReader,
        translationService: TranslationService,
        floatingPanel: FloatingTranslatePanel
    ) {
        self.selectionReader = selectionReader
        self.translationService = translationService
        self.floatingPanel = floatingPanel
    }

    func translateSelection() {
        activeTask?.cancel()
        let mouseLocation = NSEvent.mouseLocation
        let presentationID = floatingPanel.showLoading(sourceText: nil, near: mouseLocation)

        activeTask = Task { [selectionReader, translationService, floatingPanel] in
            do {
                let selectedText = try await selectionReader.readSelectedText()
                try Task.checkCancellation()

                await MainActor.run {
                    floatingPanel.updateLoading(
                        sourceText: selectedText,
                        near: mouseLocation,
                        presentationID: presentationID
                    )
                }

                let item = try await translationService.translate(
                    text: selectedText,
                    scenario: .selection,
                    mode: .selectedText
                )
                try Task.checkCancellation()

                await MainActor.run {
                    floatingPanel.showResult(
                        item: item,
                        near: mouseLocation,
                        presentationID: presentationID
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    floatingPanel.showError(
                        error.localizedDescription,
                        near: mouseLocation,
                        presentationID: presentationID
                    )
                }
            }
        }
    }
}
