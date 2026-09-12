import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics

@MainActor
final class PermissionManager {
    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    var isScreenRecordingTrusted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    var microphoneAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    var isMicrophoneTrusted: Bool {
        microphoneAuthorizationStatus == .authorized
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

    func requestMicrophoneAccess() async -> Bool {
        switch microphoneAuthorizationStatus {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
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

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func openSystemPrivacySettings() {
        openAccessibilitySettings()
    }
}
