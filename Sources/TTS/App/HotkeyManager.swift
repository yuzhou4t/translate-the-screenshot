import Foundation
import KeyboardShortcuts

@MainActor
final class HotkeyManager {
    private let translationController: SelectionTranslationController
    private let inputTranslateWindowController: InputTranslateWindowController
    private let screenshotCaptureController: ScreenshotCaptureController

    init(
        translationController: SelectionTranslationController,
        inputTranslateWindowController: InputTranslateWindowController,
        screenshotCaptureController: ScreenshotCaptureController
    ) {
        self.translationController = translationController
        self.inputTranslateWindowController = inputTranslateWindowController
        self.screenshotCaptureController = screenshotCaptureController
    }

    func start() {
        KeyboardShortcuts.onKeyUp(for: .translateSelection) { [weak self] in
            Task { @MainActor in
                self?.translationController.translateSelection()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .inputTranslate) { [weak self] in
            Task { @MainActor in
                self?.inputTranslateWindowController.show()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .screenshotTranslate) { [weak self] in
            Task { @MainActor in
                self?.screenshotCaptureController.startCapture(mode: .translate)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .screenshotOCR) { [weak self] in
            Task { @MainActor in
                self?.screenshotCaptureController.startCapture(mode: .ocr)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .silentScreenshotOCR) { [weak self] in
            Task { @MainActor in
                self?.screenshotCaptureController.startCapture(mode: .silentOCR)
            }
        }
    }

}

extension KeyboardShortcuts.Name {
    static let translateSelection = Self("translateSelection", initial: .init(.d, modifiers: [.option]))
    static let screenshotTranslate = Self("screenshotTranslate", initial: .init(.s, modifiers: [.option]))
    static let inputTranslate = Self("inputTranslate", initial: .init(.a, modifiers: [.option]))
    static let screenshotOCR = Self("screenshotOCR", initial: .init(.s, modifiers: [.shift, .option]))
    static let silentScreenshotOCR = Self("silentScreenshotOCR", initial: .init(.c, modifiers: [.option]))
}
