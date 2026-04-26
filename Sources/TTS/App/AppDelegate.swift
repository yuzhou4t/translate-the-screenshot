import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = AppServices.shared
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        services.hotkeyManager.start()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 28)
        if let button = item.button {
            button.title = ""
            button.toolTip = "TTS"
            if let image = NSImage(named: "MenuBarIconTemplate") {
                image.isTemplate = true
                image.size = NSSize(width: 22, height: 22)
                button.image = image
                button.imagePosition = .imageOnly
            } else {
                button.title = "TTS"
            }
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "翻译选中文字",
            action: #selector(translateSelection),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "输入翻译",
            action: #selector(openInputTranslate),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "截图翻译",
            action: #selector(startScreenshotTranslate),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "截图 OCR",
            action: #selector(startScreenshotOCR),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "静默截图 OCR",
            action: #selector(startSilentScreenshotOCR),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "设置...",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        menu.addItem(NSMenuItem(
            title: "历史记录",
            action: #selector(openHistory),
            keyEquivalent: "h"
        ))
        menu.addItem(NSMenuItem(
            title: "收藏夹",
            action: #selector(openFavorites),
            keyEquivalent: "f"
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "退出 TTS",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        for menuItem in menu.items {
            menuItem.target = self
        }

        item.menu = menu
        statusItem = item
    }

    @objc private func translateSelection() {
        services.translationController.translateSelection()
    }

    @objc private func openInputTranslate() {
        NSApp.activate(ignoringOtherApps: true)
        services.inputTranslateWindowController.show()
    }

    @objc private func startScreenshotTranslate() {
        services.screenshotCaptureController.startCapture(mode: .translate)
    }

    @objc private func startScreenshotOCR() {
        services.screenshotCaptureController.startCapture(mode: .ocr)
    }

    @objc private func startSilentScreenshotOCR() {
        services.screenshotCaptureController.startCapture(mode: .silentOCR)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        services.settingsWindowController.show()
    }

    @objc private func openHistory() {
        NSApp.activate(ignoringOtherApps: true)
        services.historyWindowController.show()
    }

    @objc private func openFavorites() {
        NSApp.activate(ignoringOtherApps: true)
        services.favoritesWindowController.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
