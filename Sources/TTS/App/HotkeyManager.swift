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
        KeyboardShortcuts.onKeyUp(for: .screenshotClipboard) { [weak self] in
            Task { @MainActor in
                self?.screenshotCaptureController.startCapture(mode: .clipboard)
            }
        }

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

        registerCoordinateTranslationShortcut(.screenshotTranslateOverlay)
        registerCoordinateTranslationShortcut(.screenshotTranslateOverlayAPI)
        registerCoordinateTranslationShortcut(.volcengineImageTranslation)

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

    static func coordinateTranslationMode(
        for name: KeyboardShortcuts.Name
    ) -> ScreenshotCaptureMode? {
        switch name.rawValue {
        case KeyboardShortcuts.Name.screenshotTranslateOverlay.rawValue:
            .translateOverlayLocal
        case KeyboardShortcuts.Name.screenshotTranslateOverlayAPI.rawValue:
            .translateOverlayAPI
        case KeyboardShortcuts.Name.volcengineImageTranslation.rawValue:
            .translateOverlay
        default:
            nil
        }
    }

    private func registerCoordinateTranslationShortcut(_ name: KeyboardShortcuts.Name) {
        guard let mode = Self.coordinateTranslationMode(for: name) else {
            return
        }

        KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
            Task { @MainActor in
                self?.screenshotCaptureController.startCapture(mode: mode)
            }
        }
    }

}

extension KeyboardShortcuts.Name {
    static let screenshotClipboard = Self("screenshotClipboard", initial: .init(.a, modifiers: [.control]))
    static let translateSelection = Self("translateSelection", initial: .init(.d, modifiers: [.option]))
    static let screenshotTranslate = Self("screenshotTranslate", initial: .init(.s, modifiers: [.option]))
    static let screenshotTranslateOverlay = Self("screenshotTranslateOverlay", initial: .init(.w, modifiers: [.option]))
    static let screenshotTranslateOverlayAPI = Self("screenshotTranslateOverlayAPI")
    static let volcengineImageTranslation = Self("volcengineImageTranslation")
    static let inputTranslate = Self("inputTranslate", initial: .init(.a, modifiers: [.option]))
    static let screenshotOCR = Self("screenshotOCR", initial: .init(.s, modifiers: [.shift, .option]))
    static let silentScreenshotOCR = Self("silentScreenshotOCR", initial: .init(.c, modifiers: [.option]))
}
