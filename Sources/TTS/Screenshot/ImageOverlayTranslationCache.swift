import Foundation

actor ImageOverlayTranslationCache {
    struct Key: Hashable {
        var sourceText: String
        var targetLanguage: String
        var providerID: String
        var modelName: String
        var translationMode: TranslationMode
    }

    struct Entry: Equatable {
        var translatedText: String
        var timestamp: Date
    }

    private var storage: [Key: Entry] = [:]

    func value(for key: Key) -> Entry? {
        storage[key]
    }

    func values(for keys: [Key]) -> [Key: Entry] {
        var output: [Key: Entry] = [:]
        for key in Set(keys) {
            if let value = storage[key] {
                output[key] = value
            }
        }
        return output
    }

    func insert(_ translatedText: String, for key: Key) {
        let cleanedText = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else {
            return
        }

        storage[key] = Entry(
            translatedText: cleanedText,
            timestamp: Date()
        )
    }
}
