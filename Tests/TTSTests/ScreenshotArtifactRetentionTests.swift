@testable import TTS
import AppKit
import Foundation
import KeyboardShortcuts

@MainActor
func checkCoordinateTranslationHotkeyRoutesAndDefaults() {
    precondition(
        HotkeyManager.coordinateTranslationMode(for: .screenshotTranslateOverlay)
            == .translateOverlayLocal
    )
    precondition(
        HotkeyManager.coordinateTranslationMode(for: .screenshotTranslateOverlayAPI)
            == .translateOverlayAPI
    )
    precondition(
        HotkeyManager.coordinateTranslationMode(for: .volcengineImageTranslation)
            == .translateOverlay
    )

    precondition(
        KeyboardShortcuts.Name.screenshotTranslateOverlay.rawValue
            == "screenshotTranslateOverlay"
    )
    precondition(
        KeyboardShortcuts.Name.screenshotTranslateOverlay.initial
            == .init(.w, modifiers: [.option])
    )
    precondition(KeyboardShortcuts.Name.screenshotTranslateOverlayAPI.initial == nil)
    precondition(KeyboardShortcuts.Name.volcengineImageTranslation.initial == nil)

    let rawNames = [
        KeyboardShortcuts.Name.screenshotTranslateOverlay.rawValue,
        KeyboardShortcuts.Name.screenshotTranslateOverlayAPI.rawValue,
        KeyboardShortcuts.Name.volcengineImageTranslation.rawValue
    ]
    precondition(Set(rawNames).count == rawNames.count)
}

func checkScreenshotCaptureModesRouteOverlayTranslationEngines() {
    precondition(
        ScreenshotCaptureMode.translateOverlayAPI.coordinateTranslationEngine == .configuredProvider
    )
    precondition(
        ScreenshotCaptureMode.translateOverlayLocal.coordinateTranslationEngine == .appleLocal
    )
    precondition(ScreenshotCaptureMode.translateOverlay.coordinateTranslationEngine == nil)
    precondition(ScreenshotCaptureMode.translateOverlay.usesOverlayWindow)
    precondition(ScreenshotCaptureMode.translateOverlayAPI.usesOverlayWindow)
    precondition(ScreenshotCaptureMode.translateOverlayLocal.usesOverlayWindow)
    precondition(!ScreenshotCaptureMode.translate.usesOverlayWindow)
}

func checkScreenshotOverlayRetentionRemovesOnlyExpiredOwnedArtifacts() {
    let fileManager = FileManager.default
    let baseDirectory = fileManager.temporaryDirectory
        .appendingPathComponent(
            "tts-retention-regression-\(UUID().uuidString)",
            isDirectory: true
        )
    let testDirectory = baseDirectory
        .appendingPathComponent("overlay", isDirectory: true)
    try! fileManager.createDirectory(
        at: testDirectory,
        withIntermediateDirectories: true
    )
    defer {
        try? fileManager.removeItem(at: baseDirectory)
    }

    let now = Date()
    let expiredURL = testDirectory.appendingPathComponent("expired.png")
    let recentURL = testDirectory.appendingPathComponent("recent.png")
    let externalURL = baseDirectory.appendingPathComponent("ordinary-screenshot.png")
    try! Data("expired".utf8).write(to: expiredURL)
    try! Data("recent".utf8).write(to: recentURL)
    try! Data("outside".utf8).write(to: externalURL)
    try! fileManager.setAttributes(
        [.modificationDate: now.addingTimeInterval(-4 * 24 * 60 * 60)],
        ofItemAtPath: expiredURL.path
    )
    try! fileManager.setAttributes(
        [.modificationDate: now.addingTimeInterval(-2 * 24 * 60 * 60)],
        ofItemAtPath: recentURL.path
    )
    try! fileManager.setAttributes(
        [.modificationDate: now.addingTimeInterval(-4 * 24 * 60 * 60)],
        ofItemAtPath: externalURL.path
    )

    let removedCount = try! ScreenshotArtifactRetention.removeEntriesOlderThan(
        now.addingTimeInterval(-ScreenshotArtifactRetention.retentionInterval),
        in: testDirectory,
        fileManager: fileManager
    )

    precondition(removedCount == 1)
    precondition(!fileManager.fileExists(atPath: expiredURL.path))
    precondition(fileManager.fileExists(atPath: recentURL.path))
    precondition(fileManager.fileExists(atPath: externalURL.path))
}
