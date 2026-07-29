import Foundation

enum ScreenshotArtifactRetention {
    static let retentionInterval: TimeInterval = 3 * 24 * 60 * 60

    static func overlayScreenshotDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("tts-screenshots", isDirectory: true)
            .appendingPathComponent("overlay", isDirectory: true)
    }

    static func overlayDebugDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("tts-overlay-debug", isDirectory: true)
    }

    static func pruneExpiredOverlayArtifacts(
        fileManager: FileManager = .default,
        now: Date = Date()
    ) {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        for directory in [
            overlayScreenshotDirectory(fileManager: fileManager),
            overlayDebugDirectory(fileManager: fileManager)
        ] {
            do {
                let removedCount = try removeEntriesOlderThan(
                    cutoff,
                    in: directory,
                    fileManager: fileManager
                )
                if removedCount > 0 {
                    print(
                        "screenshot overlay retention: removed=\(removedCount), directory=\(directory.path)"
                    )
                }
            } catch {
                print(
                    "screenshot overlay retention failed: directory=\(directory.path), reason=\(error.localizedDescription)"
                )
            }
        }
    }

    @discardableResult
    static func removeEntriesOlderThan(
        _ cutoff: Date,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> Int {
        guard fileManager.fileExists(atPath: directory.path) else {
            return 0
        }

        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .creationDateKey
            ],
            options: [.skipsHiddenFiles]
        )
        var removedCount = 0

        for entry in entries {
            let values = try entry.resourceValues(
                forKeys: [
                    .contentModificationDateKey,
                    .creationDateKey
                ]
            )
            guard let date = values.contentModificationDate ?? values.creationDate,
                  date < cutoff else {
                continue
            }
            try fileManager.removeItem(at: entry)
            removedCount += 1
        }

        return removedCount
    }
}
