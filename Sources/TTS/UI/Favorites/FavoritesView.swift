import AppKit
import SwiftUI

struct FavoritesView: View {
    @StateObject var viewModel: FavoritesViewModel

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
            Label("收藏夹", systemImage: "star")
                .font(.headline)

            TextField("搜索收藏内容", text: $viewModel.searchText)
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
            ProgressView("正在读取收藏夹...")
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
                title: viewModel.items.isEmpty ? "还没有收藏内容" : "没有匹配的收藏",
                message: viewModel.items.isEmpty ? "在翻译结果或历史记录中点收藏，会出现在这里。" : "换个关键词试试。",
                systemImage: viewModel.items.isEmpty ? "star" : "magnifyingglass"
            )
        } else {
            List {
                ForEach(viewModel.filteredItems) { item in
                    FavoriteRowView(
                        item: item,
                        onCopySource: {
                            viewModel.copyToPasteboard(item.historyItem.sourceText)
                        },
                        onCopyTranslation: {
                            viewModel.copyToPasteboard(item.historyItem.translatedText)
                        },
                        onRemove: {
                            Task {
                                await viewModel.remove(item)
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

private struct FavoriteRowView: View {
    var item: FavoriteItem
    var onCopySource: () -> Void
    var onCopyTranslation: () -> Void
    var onRemove: () -> Void

    private var historyItem: TranslationHistoryItem {
        item.historyItem
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MetadataPill(historyItem.providerID.displayName, systemImage: "network")
                MetadataPill(historyItem.translationMode.displayName, systemImage: historyItem.translationMode.systemImage)
                if let scenario = historyItem.scenario {
                    MetadataPill(scenario.displayName, systemImage: "point.3.connected.trianglepath.dotted")
                }
                if let modelName = historyItem.modelName, !modelName.isEmpty {
                    MetadataPill(modelName, systemImage: "cpu")
                }
                MetadataPill("收藏于 \(item.createdAt.formatted(date: .numeric, time: .shortened))", systemImage: "calendar")
                MetadataPill("备注：暂未设置", systemImage: "note.text")

                Spacer()
            }

            HStack(alignment: .top, spacing: 14) {
                TextPreview(title: "原文", text: historyItem.sourceText)
                .frame(maxWidth: .infinity, alignment: .leading)

                TextPreview(title: "译文", text: historyItem.translatedText)
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

                Spacer()

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("取消收藏", systemImage: "star.slash")
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
final class FavoritesViewModel: ObservableObject {
    @Published var items: [FavoriteItem] = []
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let favoriteStore: FavoriteStore

    init(favoriteStore: FavoriteStore) {
        self.favoriteStore = favoriteStore
    }

    var filteredItems: [FavoriteItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return items
        }

        return items.filter { item in
            item.historyItem.sourceText.localizedCaseInsensitiveContains(query) ||
                item.historyItem.translatedText.localizedCaseInsensitiveContains(query) ||
                item.historyItem.providerID.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    func load() async {
        isLoading = true
        defer {
            isLoading = false
        }

        do {
            items = try await favoriteStore.listFavorites()
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

    func remove(_ item: FavoriteItem) async {
        do {
            try await favoriteStore.removeFavorite(historyItemID: item.historyItem.id)
            items.removeAll { $0.historyItem.id == item.historyItem.id }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAll() async {
        do {
            try await favoriteStore.clearAll()
            items = []
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
