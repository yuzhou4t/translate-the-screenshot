import Foundation

actor HistoryStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("tts", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func all() async throws -> [TranslationHistoryItem] {
        try load()
    }

    func listHistory() async throws -> [TranslationHistoryItem] {
        try load()
    }

    func add(_ item: TranslationHistoryItem) async throws {
        var items = try load()
        items.insert(item, at: 0)
        items = Array(items.prefix(500))
        try save(items)
    }

    func remove(id: UUID) async throws {
        var items = try load()
        items.removeAll { $0.id == id }
        try save(items)
    }

    func clearAll() async throws {
        try save([])
    }

    private func load() throws -> [TranslationHistoryItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([TranslationHistoryItem].self, from: data)
    }

    private func save(_ items: [TranslationHistoryItem]) throws {
        let data = try encoder.encode(items)
        try data.write(to: fileURL, options: [.atomic])
    }
}
