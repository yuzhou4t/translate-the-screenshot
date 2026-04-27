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

    func translateTextOnly(
        _ text: String,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        translationMode: TranslationMode? = nil
    ) async throws -> TranslationResponse {
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
        let finalSourceLanguage = sourceLanguage ?? providerFactory.sourceLanguage

        let request = TranslationRequest(
            text: trimmedText,
            sourceLanguage: finalSourceLanguage,
            targetLanguage: finalTargetLanguage,
            translationMode: finalTranslationMode
        )

        return try await translateWithFallback(request)
    }

    func translate(
        text: String,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        translationMode: TranslationMode? = nil,
        mode: TranslationHistoryMode
    ) async throws -> TranslationHistoryItem {
        let finalTranslationMode = translationMode ?? providerFactory.defaultTranslationMode
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTargetLanguage = targetLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let response = try await translateTextOnly(
            trimmedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: finalTargetLanguage,
            translationMode: finalTranslationMode
        )
        let item = TranslationHistoryItem(
            sourceText: trimmedText,
            translatedText: response.translatedText,
            providerID: response.providerID,
            sourceLanguage: response.detectedSourceLanguage,
            targetLanguage: finalTargetLanguage?.isEmpty == false
                ? finalTargetLanguage!
                : providerFactory.targetLanguage,
            createdAt: Date(),
            mode: mode,
            translationMode: finalTranslationMode
        )

        try await historyStore.add(item)
        return item
    }

    private func translateWithFallback(_ request: TranslationRequest) async throws -> TranslationResponse {
        if request.translationMode == .ocrCleanup, !providerFactory.defaultProviderSupportsTranslationModePrompts {
            throw TranslationProviderError.providerMessage("当前默认服务不支持 AI 修复，请切换到 AI 大模型服务。")
        }

        guard let defaultConfig = providerFactory.defaultProviderConfig() else {
            throw TranslationProviderError.providerMessage("没有已启用且已接入的翻译服务。")
        }

        let fallbackConfig = request.translationMode == .ocrCleanup
            ? nil
            : providerFactory.fallbackEnabled
                ? providerFactory.fallbackProviderConfig()
                : nil

        var attemptCount = 0
        var failureKinds: [TranslationFailureKind] = []
        var fallbackAttempted = false

        do {
            attemptCount += 1
            return try await runAttempt(
                request,
                config: defaultConfig,
                modelOverride: nil,
                attemptNumber: attemptCount,
                note: "primary"
            )
        } catch {
            let firstKind = classify(error)
            failureKinds.append(firstKind)

            if firstKind == .timeout, attemptCount < 3 {
                do {
                    attemptCount += 1
                    return try await runAttempt(
                        request,
                        config: defaultConfig,
                        modelOverride: nil,
                        attemptNumber: attemptCount,
                        note: "timeout-retry"
                    )
                } catch {
                    failureKinds.append(classify(error))
                }
            }

            if let fallbackConfig,
               fallbackConfig.id != defaultConfig.id,
               attemptCount < 3 {
                do {
                    attemptCount += 1
                    fallbackAttempted = true
                    return try await runAttempt(
                        request,
                        config: fallbackConfig,
                        modelOverride: providerFactory.fallbackModel,
                        attemptNumber: attemptCount,
                        note: "fallback"
                    )
                } catch {
                    failureKinds.append(classify(error))
                }
            }
        }

        throw TranslationProviderError.providerMessage(
            finalFailureMessage(
                failureKinds: failureKinds,
                fallbackAttempted: fallbackAttempted
            )
        )
    }

    private func runAttempt(
        _ request: TranslationRequest,
        config: ProviderConfig,
        modelOverride: String?,
        attemptNumber: Int,
        note: String
    ) async throws -> TranslationResponse {
        let providerLabel = config.displayName
        let modelLabel = modelOverride ?? config.model ?? "-"
        print("translation provider attempt[\(attemptNumber)] \(note): provider=\(providerLabel), model=\(modelLabel)")

        let provider = try providerFactory.makeProvider(config: config, modelOverride: modelOverride)
        do {
            let response = try await provider.translate(request)
            print("translation provider success[\(attemptNumber)]: provider=\(providerLabel)")
            return response
        } catch {
            print("translation provider failed[\(attemptNumber)]: provider=\(providerLabel), kind=\(classify(error).rawValue), reason=\(error.localizedDescription)")
            throw error
        }
    }

    private func finalFailureMessage(
        failureKinds: [TranslationFailureKind],
        fallbackAttempted: Bool
    ) -> String {
        if failureKinds.contains(.rateLimited) {
            return fallbackAttempted
                ? "当前服务商请求失败，已尝试备用服务商，但仍未成功。请检查服务商额度或限流状态。"
                : "当前服务商请求失败，请检查服务商额度或限流状态。"
        }

        if failureKinds.contains(.invalidAPIKey) {
            return fallbackAttempted
                ? "当前服务商请求失败，已尝试备用服务商，但仍未成功。请检查 API Key、网络连接或服务商额度。"
                : "当前服务商请求失败，请检查 API Key、网络连接或服务商额度。"
        }

        return fallbackAttempted
            ? "当前服务商请求失败，已尝试备用服务商，但仍未成功。请检查 API Key、网络连接或服务商额度。"
            : "当前服务商请求失败。请检查 API Key、网络连接或服务商额度。"
    }

    private func classify(_ error: Error) -> TranslationFailureKind {
        switch error {
        case TranslationProviderError.timeout:
            return .timeout
        case TranslationProviderError.authenticationFailed,
            TranslationProviderError.missingAPIKey:
            return .invalidAPIKey
        case TranslationProviderError.rateLimited:
            return .rateLimited
        case TranslationProviderError.network:
            return .networkError
        case TranslationProviderError.invalidResponse:
            return .emptyResult
        case TranslationProviderError.invalidEndpoint,
            TranslationProviderError.providerMessage:
            return .providerError
        default:
            if let urlError = error as? URLError,
               [
                URLError.Code.notConnectedToInternet,
                .networkConnectionLost,
                .cannotFindHost,
                .cannotConnectToHost,
                .dnsLookupFailed
               ].contains(urlError.code) {
                return .networkError
            }
            return .providerError
        }
    }
}

private enum TranslationFailureKind: String {
    case timeout
    case invalidAPIKey
    case rateLimited
    case networkError
    case providerError
    case emptyResult
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
