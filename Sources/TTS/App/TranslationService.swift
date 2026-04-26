import Foundation

@MainActor
final class TranslationService {
    private let providerFactory: TranslationProviderFactory
    private let historyStore: HistoryStore

    init(providerFactory: TranslationProviderFactory, historyStore: HistoryStore) {
        self.providerFactory = providerFactory
        self.historyStore = historyStore
    }

    var defaultTargetLanguage: String {
        providerFactory.targetLanguage
    }

    func translate(
        text: String,
        targetLanguage: String? = nil,
        mode: TranslationHistoryMode
    ) async throws -> TranslationHistoryItem {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw TranslationServiceError.emptyText
        }

        let requestedTargetLanguage = targetLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTargetLanguage = requestedTargetLanguage?.isEmpty == false
            ? requestedTargetLanguage!
            : providerFactory.targetLanguage

        let request = TranslationRequest(
            text: trimmedText,
            sourceLanguage: nil,
            targetLanguage: finalTargetLanguage
        )
        let response = try await translateWithFallback(request)
        let item = TranslationHistoryItem(
            sourceText: trimmedText,
            translatedText: response.translatedText,
            providerID: response.providerID,
            sourceLanguage: response.detectedSourceLanguage,
            targetLanguage: request.targetLanguage,
            createdAt: Date(),
            mode: mode
        )

        try await historyStore.add(item)
        return item
    }

    private func translateWithFallback(_ request: TranslationRequest) async throws -> TranslationResponse {
        let attempts = providerFactory.providerAttempts()
        guard !attempts.isEmpty else {
            throw TranslationProviderError.providerMessage("没有已启用且已接入的翻译服务。")
        }

        var lastError: Error?
        for (index, attempt) in attempts.enumerated() {
            let providerName = attempt.config.displayName

            do {
                print("translation provider attempt: \(providerName)")
                let provider = try attempt.makeProvider()
                let response = try await provider.translate(request)
                print("translation provider success: \(providerName)")
                return response
            } catch {
                lastError = error
                let reason = error.localizedDescription
                print("translation provider failed: \(providerName), reason: \(reason)")

                if !shouldFallback(after: error, config: attempt.config) || index == attempts.indices.last {
                    print("translation provider fallback stopped: \(providerName)")
                    throw error
                }

                let nextProviderName = attempts[index + 1].config.displayName
                print("translation provider fallback: \(providerName) -> \(nextProviderName), reason: \(reason)")
            }
        }

        throw lastError ?? TranslationProviderError.providerMessage("所有翻译服务均失败。")
    }

    private func shouldFallback(after error: Error, config: ProviderConfig) -> Bool {
        switch error {
        case TranslationProviderError.authenticationFailed:
            return config.shouldFallbackOnAuthFailure
        case TranslationProviderError.rateLimited,
            TranslationProviderError.timeout,
            TranslationProviderError.network,
            TranslationProviderError.invalidResponse,
            TranslationProviderError.invalidEndpoint,
            TranslationProviderError.missingAPIKey,
            TranslationProviderError.providerMessage:
            return true
        default:
            if let urlError = error as? URLError {
                return [
                    .timedOut,
                    .notConnectedToInternet,
                    .networkConnectionLost,
                    .cannotFindHost,
                    .cannotConnectToHost,
                    .dnsLookupFailed
                ].contains(urlError.code)
            }
            return true
        }
    }
}

enum TranslationServiceError: LocalizedError {
    case emptyText

    var errorDescription: String? {
        switch self {
        case .emptyText:
            "请输入要翻译的文本。"
        }
    }
}
