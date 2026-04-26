import AppKit
import SwiftUI

struct InputTranslateView: View {
    @StateObject var viewModel: InputTranslateViewModel
    var onClose: () -> Void

    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            TextEditor(text: $viewModel.inputText)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 120, maxHeight: 180)
                .background(Color(NSColor.textBackgroundColor).opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .focused($isInputFocused)

            controls

            Divider()

            resultArea
        }
        .padding(18)
        .frame(width: 640, height: 520, alignment: .topLeading)
        .background(.regularMaterial)
        .onAppear {
            isInputFocused = true
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("输入翻译")
                    .font(.title3.weight(.semibold))
                Text("按 Command + Enter 翻译，按 Esc 关闭")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text("翻译方向")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: $viewModel.translationDirection) {
                ForEach(TranslationDirection.allCases) { direction in
                    Text(direction.displayName)
                        .tag(direction)
                }
            }
            .pickerStyle(.menu)
            .buttonStyle(.bordered)
            .labelsHidden()
            .frame(width: 220)

            Spacer()

            if viewModel.isTranslating {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task {
                    await viewModel.translate()
                }
            } label: {
                Label("翻译", systemImage: "arrow.right.circle")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(viewModel.isTranslating)
        }
    }

    @ViewBuilder
    private var resultArea: some View {
        if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let item = viewModel.resultItem {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(item.providerID.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.mode.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                ScrollView {
                    Text(item.translatedText)
                        .font(.system(size: 16))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 8) {
                    Button {
                        viewModel.copyToPasteboard(item.translatedText)
                    } label: {
                        Label("复制译文", systemImage: "doc.on.doc")
                    }

                    Button {
                        viewModel.copyToPasteboard(item.sourceText)
                    } label: {
                        Label("复制原文", systemImage: "doc")
                    }

                    Button {
                        Task {
                            await viewModel.toggleFavorite()
                        }
                    } label: {
                        Label(
                            viewModel.isResultFavorite ? "已收藏" : "收藏",
                            systemImage: viewModel.isResultFavorite ? "star.fill" : "star"
                        )
                    }

                    Spacer()
                }
                .controlSize(.small)
            }
        } else {
            Text("翻译结果会显示在这里")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
final class InputTranslateViewModel: ObservableObject {
    @Published var inputText = ""
    @Published var targetLanguage: String
    @Published var translationDirection: TranslationDirection
    @Published var resultItem: TranslationHistoryItem?
    @Published var isResultFavorite = false
    @Published var isTranslating = false
    @Published var errorMessage: String?

    private let translationService: TranslationService
    private let favoriteStore: FavoriteStore

    init(translationService: TranslationService, favoriteStore: FavoriteStore) {
        self.translationService = translationService
        self.favoriteStore = favoriteStore
        targetLanguage = translationService.defaultTargetLanguage
        translationDirection = TranslationDirection.inferred(from: translationService.defaultTargetLanguage)
    }

    func translate() async {
        isTranslating = true
        errorMessage = nil
        defer {
            isTranslating = false
        }

        do {
            let item = try await translationService.translate(
                text: inputText,
                sourceLanguage: translationDirection.sourceLanguage,
                targetLanguage: translationDirection.targetLanguage ?? targetLanguage,
                scenario: .input,
                mode: .input
            )
            resultItem = item
            isResultFavorite = try await favoriteStore.isFavorite(historyItemID: item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func toggleFavorite() async {
        guard let resultItem else {
            return
        }

        do {
            if isResultFavorite {
                try await favoriteStore.removeFavorite(historyItemID: resultItem.id)
                isResultFavorite = false
            } else {
                try await favoriteStore.addFavorite(resultItem)
                isResultFavorite = true
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
