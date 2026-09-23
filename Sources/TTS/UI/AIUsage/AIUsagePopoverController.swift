import AppKit
import SwiftUI

@MainActor
final class AIUsagePopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let usageStore: AIUsageStore
    private let codexAccountSwitcherStore: CodexAccountSwitcherStore
    private weak var statusButton: NSStatusBarButton?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?

    init(
        usageStore: AIUsageStore,
        tokenStore: AIUsageTokenStore,
        settingsStore: AIUsageSettingsStore,
        codexAccountSwitcherStore: CodexAccountSwitcherStore,
        screenRecordingController: ScreenRecordingController,
        onQuickAction: @escaping (MenuQuickActionID) -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.usageStore = usageStore
        self.codexAccountSwitcherStore = codexAccountSwitcherStore
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: AIUsagePopoverView(
                usageStore: usageStore,
                tokenStore: tokenStore,
                settingsStore: settingsStore,
                codexAccountSwitcherStore: codexAccountSwitcherStore,
                screenRecordingController: screenRecordingController,
                onQuickAction: onQuickAction,
                onOpenSettings: onOpenSettings,
                onQuit: onQuit,
                forceReduceTransparency: nil
            )
        )
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
            return
        }
        show(relativeTo: button)
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard !popover.isShown else { return }
        statusButton = button
        usageStore.refreshIfStale()
        codexAccountSwitcherStore.reload()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installDismissMonitorsIfNeeded()
    }

    func close() {
        removeDismissMonitors()
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        removeDismissMonitors()
    }

    private func installDismissMonitorsIfNeeded() {
        guard localMouseDownMonitor == nil, globalMouseDownMonitor == nil else {
            return
        }

        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor in
                self?.closeIfClickIsOutsidePopover()
            }
            return event
        }

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor in
                self?.closeIfClickIsOutsidePopover()
            }
        }
    }

    private func removeDismissMonitors() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
    }

    private func closeIfClickIsOutsidePopover() {
        guard popover.isShown,
              let popoverWindow = popover.contentViewController?.view.window else {
            removeDismissMonitors()
            return
        }

        let clickLocation = NSEvent.mouseLocation
        if popoverWindow.frame.contains(clickLocation) {
            return
        }
        if let statusButton,
           let statusWindow = statusButton.window {
            let buttonFrame = statusWindow.convertToScreen(statusButton.convert(statusButton.bounds, to: nil))
            if buttonFrame.contains(clickLocation) {
                return
            }
        }
        close()
    }
}
