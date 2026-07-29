@testable import TTS
import Foundation

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

func checkScreenshotOverlayHistoryExpiresAfterThreeDays() {
    let now = Date()
    let expiredOverlay = makeRetentionHistoryItem(
        mode: .imageOverlay,
        createdAt: now.addingTimeInterval(-4 * 24 * 60 * 60)
    )
    let recentOverlay = makeRetentionHistoryItem(
        mode: .imageOverlay,
        createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60)
    )
    let oldScreenshotTranslation = makeRetentionHistoryItem(
        mode: .ocrTranslate,
        createdAt: now.addingTimeInterval(-30 * 24 * 60 * 60)
    )

    let retained = HistoryStore.retainingUnexpiredImageOverlayItems(
        [
            expiredOverlay,
            recentOverlay,
            oldScreenshotTranslation
        ],
        now: now
    )

    precondition(!retained.contains(where: { $0.id == expiredOverlay.id }))
    precondition(retained.contains(where: { $0.id == recentOverlay.id }))
    precondition(retained.contains(where: { $0.id == oldScreenshotTranslation.id }))
}

private func makeRetentionHistoryItem(
    mode: TranslationHistoryMode,
    createdAt: Date
) -> TranslationHistoryItem {
    TranslationHistoryItem(
        sourceText: "source",
        translatedText: "translation",
        providerID: .localOCR,
        sourceLanguage: nil,
        targetLanguage: "zh-CN",
        createdAt: createdAt,
        mode: mode,
        translationMode: .imageOverlay
    )
}
