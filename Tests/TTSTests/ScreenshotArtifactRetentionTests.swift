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

func checkTranslationHistoryUsesModeSpecificRetention() {
    let now = Date()
    let expiredOverlay = makeRetentionHistoryItem(
        mode: .imageOverlay,
        createdAt: now.addingTimeInterval(-4 * 24 * 60 * 60)
    )
    let recentOverlay = makeRetentionHistoryItem(
        mode: .imageOverlay,
        createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60)
    )
    let overlayAtCutoff = makeRetentionHistoryItem(
        mode: .imageOverlay,
        createdAt: now.addingTimeInterval(-HistoryStore.imageOverlayRetentionInterval)
    )
    let ordinaryModes: [TranslationHistoryMode] = [
        .selectedText,
        .ocr,
        .ocrTranslate,
        .input
    ]
    let expiredOrdinaryItems = ordinaryModes.map {
        makeRetentionHistoryItem(
            mode: $0,
            createdAt: now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
    }
    let recentOrdinaryItems = ordinaryModes.map {
        makeRetentionHistoryItem(
            mode: $0,
            createdAt: now.addingTimeInterval(-6 * 24 * 60 * 60)
        )
    }
    let ordinaryItemAtCutoff = makeRetentionHistoryItem(
        mode: .selectedText,
        createdAt: now.addingTimeInterval(-HistoryStore.ordinaryHistoryRetentionInterval)
    )

    let retained = HistoryStore.retainingUnexpiredItems(
        [
            expiredOverlay,
            recentOverlay,
            overlayAtCutoff,
            ordinaryItemAtCutoff
        ] + expiredOrdinaryItems + recentOrdinaryItems,
        now: now
    )

    precondition(!retained.contains(where: { $0.id == expiredOverlay.id }))
    precondition(retained.contains(where: { $0.id == recentOverlay.id }))
    precondition(retained.contains(where: { $0.id == overlayAtCutoff.id }))
    precondition(retained.contains(where: { $0.id == ordinaryItemAtCutoff.id }))
    for item in expiredOrdinaryItems {
        precondition(!retained.contains(where: { $0.id == item.id }))
    }
    for item in recentOrdinaryItems {
        precondition(retained.contains(where: { $0.id == item.id }))
    }
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
