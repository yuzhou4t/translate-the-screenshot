import Foundation

#if canImport(Translation)
import Translation

@available(macOS 15.0, *)
final class AppleTranslationProvider: IdentifiedBatchTranslationProvider, @unchecked Sendable {
    let id: TranslationProviderID = .appleTranslation
    let displayName = "Apple 本地翻译"

    private let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }

    func translateBatch(
        _ items: [IdentifiedTranslationText],
        sourceLanguage _: String?,
        targetLanguage _: String
    ) async throws -> [IdentifiedTranslationTextResult] {
        var results: [IdentifiedTranslationTextResult] = []
        for try await response in translateBatchAsStream(items) {
            guard let id = response.clientIdentifier else {
                continue
            }
            results.append(
                IdentifiedTranslationTextResult(
                    id: id,
                    translatedText: response.targetText
                )
            )
        }
        return results
    }

    func translateBatchAsStream(
        _ items: [IdentifiedTranslationText]
    ) -> TranslationSession.BatchResponse {
        let requests = items.map {
            TranslationSession.Request(
                sourceText: $0.text,
                clientIdentifier: $0.id
            )
        }
        return session.translate(batch: requests)
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        let response = try await session.translate(request.text)
        return TranslationResponse(
            translatedText: response.targetText,
            providerID: id,
            detectedSourceLanguage: nil
        )
    }
}
#endif
