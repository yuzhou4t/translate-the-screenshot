import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = AppServices.shared
    private var statusItem: NSStatusItem?
    private var popoverController: AIUsagePopoverController?
    private var translationWarmUpTask: Task<Void, Never>?
    private var isTerminatingAfterRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        services.hotkeyManager.start()
        services.screenRecordingController.onStateChanged = { [weak self] in
            self?.updateStatusItemAppearance()
        }
        services.screenRecordingController.onRequestControls = { [weak self] in
            self?.showStatusPopover()
        }
        services.aiUsageStore.start()
        ScreenshotArtifactRetention.pruneExpiredOverlayArtifacts()
        scheduleTranslationWarmUp()
    }

    func applicationWillTerminate(_ notification: Notification) {
        translationWarmUpTask?.cancel()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminatingAfterRecording else {
            return .terminateNow
        }

        if services.screenRecordingController.isFinalizing {
            isTerminatingAfterRecording = true
            Task { [weak self] in
                guard let self else { return }
                await self.services.screenRecordingController.prepareForTermination()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }

        guard services.screenRecordingController.isRecordingSession else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "正在录屏"
        alert.informativeText = "退出前需要停止并保存当前录屏，避免丢失已经录制的内容。"
        alert.addButton(withTitle: "停止并保存后退出")
        alert.addButton(withTitle: "继续录制")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        isTerminatingAfterRecording = true
        Task { [weak self] in
            guard let self else { return }
            await self.services.screenRecordingController.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func scheduleTranslationWarmUp() {
        translationWarmUpTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else {
                return
            }
            await self.services.providerRegistry.warmUpDefaultProvider()
        }
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
            button.target = self
            button.action = #selector(toggleStatusPopover(_:))
            button.sendAction(on: [.leftMouseUp])
        }
        popoverController = AIUsagePopoverController(
            usageStore: services.aiUsageStore,
            tokenStore: services.aiUsageTokenStore,
            settingsStore: services.aiUsageSettingsStore,
            codexAccountSwitcherStore: services.codexAccountSwitcherStore,
            screenRecordingController: services.screenRecordingController,
            onQuickAction: { [weak self] action in
                self?.performQuickAction(action)
            },
            onOpenSettings: { [weak self] in
                self?.popoverController?.close()
                NSApp.activate(ignoringOtherApps: true)
                self?.services.settingsWindowController.show(tab: .aiUsage)
            },
            onQuit: { [weak self] in
                self?.popoverController?.close()
                NSApp.terminate(nil)
            }
        )
        statusItem = item
        updateStatusItemAppearance()
    }

    @objc private func toggleStatusPopover(_ sender: NSStatusBarButton) {
        popoverController?.toggle(relativeTo: sender)
    }

    private func performQuickAction(_ action: MenuQuickActionID) {
        popoverController?.close()
        switch action {
        case .screenRecording:
            services.screenRecordingController.startSelection()
        case .screenshotClipboard:
            startScreenshotClipboard()
        case .translateSelection:
            translateSelection()
        case .inputTranslate:
            openInputTranslate()
        case .screenshotTranslate:
            startScreenshotTranslate()
        case .localOverlayTranslate:
            startLocalScreenshotOverlayTranslate()
        case .apiOverlayTranslate:
            startAPIScreenshotOverlayTranslate()
        case .volcengineImageTranslate:
            startScreenshotOverlayTranslate()
        case .screenshotOCR:
            startScreenshotOCR()
        case .silentScreenshotOCR:
            startSilentScreenshotOCR()
        case .imageFileOCR:
            openImageFileOCR()
        }
    }

    private func showStatusPopover() {
        guard let button = statusItem?.button else { return }
        popoverController?.show(relativeTo: button)
    }

    private func updateStatusItemAppearance() {
        guard let item = statusItem, let button = item.button else { return }
        let state = services.screenRecordingController.state
        switch state {
        case .recording:
            item.length = NSStatusItem.variableLength
            configureActiveStatusItem(
                button,
                symbolName: "record.circle.fill",
                title: services.screenRecordingController.formattedElapsed,
                color: .white,
                accessibilityLabel: "正在录屏"
            )
            button.toolTip = "正在录屏"
        case .paused:
            item.length = NSStatusItem.variableLength
            configureActiveStatusItem(
                button,
                symbolName: "pause.circle.fill",
                title: services.screenRecordingController.formattedElapsed,
                color: .systemOrange,
                accessibilityLabel: "录屏已暂停"
            )
            button.toolTip = "录屏已暂停"
        case .finalizing:
            item.length = NSStatusItem.variableLength
            configureActiveStatusItem(
                button,
                symbolName: "arrow.down.circle",
                title: "保存中",
                color: .controlAccentColor,
                accessibilityLabel: "正在保存录屏"
            )
            button.toolTip = "正在保存录屏"
        case .idle, .selecting, .countdown, .completed, .failed:
            item.length = 28
            button.title = ""
            button.contentTintColor = nil
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("TTS")
            button.toolTip = "TTS"
            if let image = NSImage(named: "MenuBarIconTemplate") {
                image.isTemplate = true
                image.size = NSSize(width: 22, height: 22)
                button.image = image
            }
        }
    }

    private func configureActiveStatusItem(
        _ button: NSStatusBarButton,
        symbolName: String,
        title: String,
        color: NSColor,
        accessibilityLabel: String
    ) {
        button.title = ""
        button.contentTintColor = nil
        button.imagePosition = .imageOnly
        button.image = activeStatusItemImage(
            symbolName: symbolName,
            title: title,
            color: color,
            accessibilityLabel: accessibilityLabel
        )
        button.setAccessibilityLabel("\(accessibilityLabel) \(title)")
    }

    private func activeStatusItemImage(
        symbolName: String,
        title: String,
        color: NSColor,
        accessibilityLabel: String
    ) -> NSImage? {
        let symbolConfiguration = NSImage.SymbolConfiguration(paletteColors: [color])
        guard let symbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(symbolConfiguration) else {
            return nil
        }

        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: font,
        ]
        let attributedTitle = NSAttributedString(string: title, attributes: attributes)
        let textSize = attributedTitle.size()
        let symbolSize = NSSize(width: 15, height: 15)
        let spacing: CGFloat = 4
        let imageSize = NSSize(
            width: symbolSize.width + spacing + ceil(textSize.width),
            height: max(symbolSize.height, ceil(textSize.height))
        )
        let image = NSImage(size: imageSize, flipped: false) { rect in
            symbol.draw(
                in: NSRect(
                    x: rect.minX,
                    y: rect.midY - symbolSize.height / 2,
                    width: symbolSize.width,
                    height: symbolSize.height
                )
            )
            attributedTitle.draw(
                at: NSPoint(
                    x: rect.minX + symbolSize.width + spacing,
                    y: rect.midY - textSize.height / 2
                )
            )
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "\(accessibilityLabel) \(title)"
        return image
    }

    @objc private func translateSelection() {
        services.translationController.translateSelection()
    }

    @objc private func startScreenshotClipboard() {
        services.screenshotCaptureController.startCapture(mode: .clipboard)
    }

    @objc private func openInputTranslate() {
        NSApp.activate(ignoringOtherApps: true)
        services.inputTranslateWindowController.show()
    }

    @objc private func startScreenshotTranslate() {
        services.screenshotCaptureController.startCapture(mode: .translate)
    }

    @objc private func startScreenshotOverlayTranslate() {
        services.screenshotCaptureController.startCapture(mode: .translateOverlay)
    }

    @objc private func startAPIScreenshotOverlayTranslate() {
        services.screenshotCaptureController.startCapture(mode: .translateOverlayAPI)
    }

    @objc private func startLocalScreenshotOverlayTranslate() {
        services.screenshotCaptureController.startCapture(mode: .translateOverlayLocal)
    }

    @objc private func startScreenshotOCR() {
        services.screenshotCaptureController.startCapture(mode: .ocr)
    }

    @objc private func startSilentScreenshotOCR() {
        services.screenshotCaptureController.startCapture(mode: .silentOCR)
    }

    @objc private func openImageFileOCR() {
        services.screenshotCaptureController.openImageFileOCR()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        services.settingsWindowController.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
