import Foundation

actor ImageOverlayTranslationCache {
    static let defaultMaximumEntryCount = 500
    static let defaultRetentionInterval: TimeInterval = 24 * 60 * 60

    struct Key: Hashable {
        var sourceText: String
        var targetLanguage: String
        var providerID: String
        var modelName: String
        var translationMode: TranslationMode
    }

    struct Entry: Equatable {
        var translatedText: String
        var lineTranslations: [SegmentLineTranslation]
        var timestamp: Date
    }

    private var storage: [Key: Entry] = [:]
    private let maximumEntryCount: Int
    private let retentionInterval: TimeInterval

    init(
        maximumEntryCount: Int = defaultMaximumEntryCount,
        retentionInterval: TimeInterval = defaultRetentionInterval
    ) {
        self.maximumEntryCount = max(maximumEntryCount, 1)
        self.retentionInterval = max(retentionInterval, 0)
    }

    func value(for key: Key) -> Entry? {
        let now = Date()
        removeExpiredEntries(now: now)
        guard var entry = storage[key] else {
            return nil
        }
        entry.timestamp = now
        storage[key] = entry
        return entry
    }

    func values(for keys: [Key]) -> [Key: Entry] {
        let now = Date()
        removeExpiredEntries(now: now)
        var output: [Key: Entry] = [:]
        for key in Set(keys) {
            if var entry = storage[key] {
                entry.timestamp = now
                storage[key] = entry
                output[key] = entry
            }
        }
        return output
    }

    func insert(
        translatedText: String,
        lineTranslations: [SegmentLineTranslation],
        for key: Key
    ) {
        let cleanedText = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else {
            return
        }

        let now = Date()
        removeExpiredEntries(now: now)
        storage[key] = Entry(
            translatedText: cleanedText,
            lineTranslations: lineTranslations,
            timestamp: now
        )
        removeLeastRecentlyUsedEntriesIfNeeded()
    }

    private func removeExpiredEntries(now: Date) {
        guard retentionInterval > 0 else {
            storage.removeAll()
            return
        }
        let cutoff = now.addingTimeInterval(-retentionInterval)
        storage = storage.filter { $0.value.timestamp >= cutoff }
    }

    private func removeLeastRecentlyUsedEntriesIfNeeded() {
        while storage.count > maximumEntryCount,
              let oldestKey = storage.min(by: {
                  $0.value.timestamp < $1.value.timestamp
              })?.key {
            storage.removeValue(forKey: oldestKey)
        }
    }
}
