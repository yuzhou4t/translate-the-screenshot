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

    var defaultTranslationMode: TranslationMode {
        providerFactory.defaultTranslationMode
    }

    func translate(
        text: String,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        translationMode: TranslationMode? = nil,
        scenario: TranslationScenario? = nil,
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
        let finalTranslationMode = translationMode ?? providerFactory.defaultTranslationMode
        let finalScenario = scenarioFor(
            explicitScenario: scenario,
            mode: mode,
            translationMode: finalTranslationMode
        )
        let finalSourceLanguage = sourceLanguage ?? providerFactory.sourceLanguage

        let request = TranslationRequest(
            text: trimmedText,
            sourceLanguage: finalSourceLanguage,
            targetLanguage: finalTargetLanguage,
            translationMode: finalTranslationMode
        )
        let result = try await translateWithFallback(
            request,
            scenario: finalScenario,
            translationMode: finalTranslationMode
        )
        let item = TranslationHistoryItem(
            sourceText: trimmedText,
            translatedText: result.response.translatedText,
            providerID: result.response.providerID,
            sourceLanguage: result.response.detectedSourceLanguage,
            targetLanguage: request.targetLanguage,
            createdAt: Date(),
            mode: mode,
            translationMode: finalTranslationMode,
            modelName: result.modelName,
            scenario: finalScenario
        )

        try await historyStore.add(item)
        return item
    }

    private func translateWithFallback(
        _ request: TranslationRequest,
        scenario: TranslationScenario,
        translationMode: TranslationMode
    ) async throws -> TranslationAttemptResult {
        let attempts = providerAttempts(
            scenario: scenario,
            translationMode: translationMode
        )
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
                return TranslationAttemptResult(
                    response: response,
                    modelName: attempt.config.model
                )
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

    private func providerAttempts(
        scenario: TranslationScenario,
        translationMode: TranslationMode
    ) -> [ProviderAttempt] {
        var attempts = providerFactory.providerAttempts()
        let routableProfiles = providerFactory.modelProfiles.filter { profile in
            providerFactory.isProviderReady(for: profile.providerID)
        }
        guard let profile = TranslationRouter().recommendedProfile(
            for: scenario,
            modelProfiles: routableProfiles,
            translationMode: translationMode
        ), var config = providerFactory.providerConfig(for: profile.providerID) else {
            return attempts
        }

        config.shouldFallbackOnAuthFailure = true
        config.model = profile.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? config.model
            : profile.modelName.trimmingCharacters(in: .whitespacesAndNewlines)

        let routedAttempt = providerFactory.providerAttempt(config: config)
        attempts.removeAll { $0.config.id == config.id }
        attempts.insert(routedAttempt, at: 0)
        return attempts
    }

    private func scenarioFor(
        explicitScenario: TranslationScenario?,
        mode: TranslationHistoryMode,
        translationMode: TranslationMode
    ) -> TranslationScenario {
        switch translationMode {
        case .technical:
            return .technical
        case .academic:
            return .academic
        case .ocrCleanup:
            return .ocrCleanup
        case .fast, .accurate, .natural, .bilingual, .polished:
            break
        }

        if let explicitScenario {
            return explicitScenario
        }

        switch mode {
        case .selectedText:
            return .selection
        case .input:
            return .input
        case .ocrTranslate:
            return .screenshot
        case .ocr:
            return .ocrCleanup
        }
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

private struct TranslationAttemptResult {
    var response: TranslationResponse
    var modelName: String?
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
