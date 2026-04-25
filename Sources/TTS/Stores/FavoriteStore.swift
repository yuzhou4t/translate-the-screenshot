import Foundation

actor FavoriteStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("tts", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("favorites.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func listFavorites() async throws -> [FavoriteItem] {
        try load()
    }

    func all() async throws -> [FavoriteItem] {
        try await listFavorites()
    }

    func addFavorite(_ historyItem: TranslationHistoryItem) async throws {
        var items = try load()
        guard !items.contains(where: { $0.historyItem.id == historyItem.id }) else {
            return
        }

        items.insert(FavoriteItem(historyItem: historyItem), at: 0)
        try save(items)
    }

    func add(_ item: FavoriteItem) async throws {
        try await addFavorite(item.historyItem)
    }

    func removeFavorite(historyItemID: UUID) async throws {
        var items = try load()
        items.removeAll { $0.historyItem.id == historyItemID }
        try save(items)
    }

    func removeFavorites(historyItemIDs: Set<UUID>) async throws {
        guard !historyItemIDs.isEmpty else {
            return
        }

        var items = try load()
        items.removeAll { historyItemIDs.contains($0.historyItem.id) }
        try save(items)
    }

    func clearAll() async throws {
        try save([])
    }

    func isFavorite(historyItemID: UUID) async throws -> Bool {
        let items = try load()
        return items.contains { $0.historyItem.id == historyItemID }
    }

    private func load() throws -> [FavoriteItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([FavoriteItem].self, from: data)
    }

    private func save(_ items: [FavoriteItem]) throws {
        let data = try encoder.encode(items)
        try data.write(to: fileURL, options: [.atomic])
    }
}
