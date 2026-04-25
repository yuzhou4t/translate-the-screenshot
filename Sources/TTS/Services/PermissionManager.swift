import ApplicationServices
import AppKit
import CoreGraphics

@MainActor
final class PermissionManager {
    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    var isScreenRecordingTrusted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func openAccessibilityPromptIfNeeded() {
        guard !isAccessibilityTrusted else {
            return
        }

        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func requestAccessibilityAndOpenSettingsIfNeeded() {
        openAccessibilityPromptIfNeeded()
        guard !isAccessibilityTrusted else {
            return
        }
        openAccessibilitySettings()
    }

    func requestScreenRecordingIfNeeded() {
        guard !isScreenRecordingTrusted else {
            return
        }

        CGRequestScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func openSystemPrivacySettings() {
        openAccessibilitySettings()
    }
}
