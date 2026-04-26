import AppKit
import SwiftUI

struct HistoryView: View {
    @StateObject var viewModel: HistoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(minWidth: 760, minHeight: 460)
        .background(.background)
        .task {
            await viewModel.load()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("历史记录", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            TextField("搜索原文或译文", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            Text("\(viewModel.filteredItems.count) 条")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())

            Spacer()

            Button {
                Task {
                    await viewModel.load()
                }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }

            Button(role: .destructive) {
                Task {
                    await viewModel.clearAll()
                }
            } label: {
                Label("清空全部", systemImage: "trash")
            }
            .disabled(viewModel.items.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView("正在读取历史记录...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.errorMessage {
            VStack(spacing: 12) {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("重试") {
                    Task {
                        await viewModel.load()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if viewModel.filteredItems.isEmpty {
            EmptyStateView(
                title: viewModel.items.isEmpty ? "还没有历史记录" : "没有匹配的记录",
                message: viewModel.items.isEmpty ? "完成一次翻译后会自动保存到这里。" : "换个关键词试试。",
                systemImage: viewModel.items.isEmpty ? "clock" : "magnifyingglass"
            )
        } else {
            List {
                ForEach(viewModel.filteredItems) { item in
                    HistoryRowView(
                        item: item,
                        isFavorite: viewModel.favoriteIDs.contains(item.id),
                        onCopySource: {
                            viewModel.copyToPasteboard(item.sourceText)
                        },
                        onCopyTranslation: {
                            viewModel.copyToPasteboard(item.translatedText)
                        },
                        onToggleFavorite: {
                            Task {
                                await viewModel.toggleFavorite(item)
                            }
                        },
                        onDelete: {
                            Task {
                                await viewModel.delete(item)
                            }
                        }
                    )
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct HistoryRowView: View {
    var item: TranslationHistoryItem
    var isFavorite: Bool
    var onCopySource: () -> Void
    var onCopyTranslation: () -> Void
    var onToggleFavorite: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MetadataPill(item.providerID.displayName, systemImage: "network")
                MetadataPill(item.mode.displayName, systemImage: "tag")
                MetadataPill(item.translationMode.displayName, systemImage: item.translationMode.systemImage)
                if let scenario = item.scenario {
                    MetadataPill(scenario.displayName, systemImage: "point.3.connected.trianglepath.dotted")
                }
                if let modelName = item.modelName, !modelName.isEmpty {
                    MetadataPill(modelName, systemImage: "cpu")
                }

                Text(item.createdAt.formatted(date: .numeric, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            HStack(alignment: .top, spacing: 14) {
                TextPreview(title: "原文", text: item.sourceText)
                .frame(maxWidth: .infinity, alignment: .leading)

                TextPreview(title: "译文", text: item.translatedText)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button {
                    onCopySource()
                } label: {
                    Label("复制原文", systemImage: "doc")
                }

                Button {
                    onCopyTranslation()
                } label: {
                    Label("复制译文", systemImage: "doc.on.doc")
                }

                Button {
                    onToggleFavorite()
                } label: {
                    Label(isFavorite ? "已收藏" : "收藏", systemImage: isFavorite ? "star.fill" : "star")
                }

                Spacer()

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }
}

private struct MetadataPill: View {
    var text: String
    var systemImage: String

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

private struct TextPreview: View {
    var title: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
        }
    }
}

private struct EmptyStateView: View {
    var title: String
    var message: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var items: [TranslationHistoryItem] = []
    @Published var favoriteIDs: Set<UUID> = []
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let historyStore: HistoryStore
    private let favoriteStore: FavoriteStore

    init(historyStore: HistoryStore, favoriteStore: FavoriteStore) {
        self.historyStore = historyStore
        self.favoriteStore = favoriteStore
    }

    var filteredItems: [TranslationHistoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return items
        }

        return items.filter { item in
            item.sourceText.localizedCaseInsensitiveContains(query) ||
                item.translatedText.localizedCaseInsensitiveContains(query)
        }
    }

    func load() async {
        isLoading = true
        defer {
            isLoading = false
        }

        do {
            items = try await historyStore.listHistory()
            favoriteIDs = Set(try await favoriteStore.listFavorites().map(\.historyItem.id))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func toggleFavorite(_ item: TranslationHistoryItem) async {
        do {
            if favoriteIDs.contains(item.id) {
                try await favoriteStore.removeFavorite(historyItemID: item.id)
                favoriteIDs.remove(item.id)
            } else {
                try await favoriteStore.addFavorite(item)
                favoriteIDs.insert(item.id)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ item: TranslationHistoryItem) async {
        do {
            try await historyStore.remove(id: item.id)
            try await favoriteStore.removeFavorite(historyItemID: item.id)
            items.removeAll { $0.id == item.id }
            favoriteIDs.remove(item.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAll() async {
        do {
            let ids = Set(items.map(\.id))
            try await historyStore.clearAll()
            try await favoriteStore.removeFavorites(historyItemIDs: ids)
            items = []
            favoriteIDs.subtract(ids)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
