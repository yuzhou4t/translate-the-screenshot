import Foundation

struct MyMemoryProvider: IdentifiedBatchTranslationProvider {
    let id: TranslationProviderID = .myMemory
    let displayName = "MyMemory 免费测试"

    static let maximumTextBytes = 500
    private static let batchMarkerPrefix = "[[TTSB"
    private static let closingBatchMarkerPrefix = "[[/TTSB"

    private let endpoint = URL(string: "https://api.mymemory.translated.net/get")!
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        guard Data(request.text.utf8).count <= Self.maximumTextBytes else {
            throw TranslationProviderError.providerMessage("MyMemory 免费接口单次最多支持约 500 bytes 文本，请选短一点再试。")
        }

        let sourceLanguage = sourceLanguageCode(from: request.sourceLanguage)
        let translatedText = try await requestTranslation(
            request.text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguageCode(from: request.targetLanguage)
        )

        return TranslationResponse(
            translatedText: translatedText,
            providerID: id,
            detectedSourceLanguage: sourceLanguage
        )
    }

    func translateBatch(
        _ items: [IdentifiedTranslationText],
        sourceLanguage: String?,
        targetLanguage: String
    ) async throws -> [IdentifiedTranslationTextResult] {
        let payloads = Self.makeBatchPayloads(from: items)
        guard !payloads.isEmpty else {
            return []
        }

        let sourceLanguageCode = sourceLanguageCode(from: sourceLanguage)
        let targetLanguageCode = targetLanguageCode(from: targetLanguage)
        var output: [IdentifiedTranslationTextResult] = []
        output.reserveCapacity(items.count)

        for payload in payloads {
            let translatedText = try await requestTranslation(
                payload.query,
                sourceLanguage: sourceLanguageCode,
                targetLanguage: targetLanguageCode
            )
            output.append(contentsOf: Self.parseBatchTranslation(
                translatedText,
                payload: payload
            ))
        }

        return output
    }

    static func makeBatchPayloads(
        from items: [IdentifiedTranslationText]
    ) -> [BatchPayload] {
        var payloads: [BatchPayload] = []
        var currentFragments: [String] = []
        var currentEntries: [BatchEntry] = []
        var seenIDs = Set<String>()

        func flushCurrentPayload() {
            guard !currentFragments.isEmpty else {
                return
            }
            payloads.append(
                BatchPayload(
                    query: currentFragments.joined(separator: "\n"),
                    entries: currentEntries
                )
            )
            currentFragments.removeAll(keepingCapacity: true)
            currentEntries.removeAll(keepingCapacity: true)
        }

        for (index, item) in items.enumerated() {
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  !text.isEmpty,
                  !seenIDs.contains(id),
                  !text.contains(batchMarkerPrefix),
                  !text.contains(closingBatchMarkerPrefix) else {
                continue
            }
            seenIDs.insert(id)

            let entry = BatchEntry(index: index, id: id)
            let fragment = framedText(text, for: entry)
            guard Data(fragment.utf8).count <= maximumTextBytes else {
                continue
            }

            let candidate = (currentFragments + [fragment]).joined(separator: "\n")
            if Data(candidate.utf8).count > maximumTextBytes {
                flushCurrentPayload()
            }

            currentFragments.append(fragment)
            currentEntries.append(entry)
        }

        flushCurrentPayload()
        return payloads
    }

    static func parseBatchTranslation(
        _ translatedText: String,
        payload: BatchPayload
    ) -> [IdentifiedTranslationTextResult] {
        var output: [IdentifiedTranslationTextResult] = []
        output.reserveCapacity(payload.entries.count)

        for entry in payload.entries {
            let startMarker = marker(for: entry, closing: false)
            let endMarker = marker(for: entry, closing: true)
            guard let startRange = uniqueRange(of: startMarker, in: translatedText),
                  let endRange = uniqueRange(of: endMarker, in: translatedText),
                  startRange.upperBound <= endRange.lowerBound else {
                continue
            }

            let translation = String(translatedText[startRange.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translation.isEmpty,
                  !translation.contains(batchMarkerPrefix),
                  !translation.contains(closingBatchMarkerPrefix) else {
                continue
            }

            output.append(
                IdentifiedTranslationTextResult(
                    id: entry.id,
                    translatedText: translation
                )
            )
        }

        return output
    }

    private func requestTranslation(
        _ text: String,
        sourceLanguage: String,
        targetLanguage: String
    ) async throws -> String {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "\(sourceLanguage)|\(targetLanguage)")
        ]

        guard let url = components?.url else {
            throw TranslationProviderError.invalidEndpoint
        }

        let (data, response) = try await urlSession.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw TranslationProviderError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(MyMemoryResponse.self, from: data)
        guard decoded.responseStatus == 200 else {
            throw TranslationProviderError.providerMessage(decoded.responseDetails ?? "MyMemory 翻译失败。")
        }

        let translatedText = decoded.responseData.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translatedText.isEmpty else {
            throw TranslationProviderError.invalidResponse
        }

        return translatedText
    }

    private static func framedText(
        _ text: String,
        for entry: BatchEntry
    ) -> String {
        [
            marker(for: entry, closing: false),
            text,
            marker(for: entry, closing: true)
        ]
        .joined(separator: "\n")
    }

    private static func marker(
        for entry: BatchEntry,
        closing: Bool
    ) -> String {
        closing
            ? "[[/TTSB\(entry.index)]]"
            : "[[TTSB\(entry.index)]]"
    }

    private static func uniqueRange(
        of marker: String,
        in text: String
    ) -> Range<String.Index>? {
        guard let range = text.range(of: marker),
              text.range(of: marker, range: range.upperBound..<text.endIndex) == nil else {
            return nil
        }
        return range
    }

    private func sourceLanguageCode(from sourceLanguage: String?) -> String {
        guard let sourceLanguage, !sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "en"
        }

        return normalizeLanguageCode(sourceLanguage)
    }

    private func targetLanguageCode(from targetLanguage: String) -> String {
        normalizeLanguageCode(targetLanguage)
    }

    private func normalizeLanguageCode(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chinese", "中文", "简体中文", "zh", "zh-cn":
            return "zh-CN"
        case "traditional chinese", "繁体中文", "zh-tw":
            return "zh-TW"
        case "english", "英语", "en", "en-us", "en-gb":
            return "en"
        case "japanese", "日语", "ja", "jp":
            return "ja"
        case "korean", "韩语", "ko", "kr":
            return "ko"
        case "french", "法语", "fr":
            return "fr"
        case "german", "德语", "de":
            return "de"
        case "spanish", "西班牙语", "es":
            return "es"
        case "russian", "俄语", "ru":
            return "ru"
        default:
            return value
        }
    }

    struct BatchPayload: Equatable {
        var query: String
        var entries: [BatchEntry]
    }

    struct BatchEntry: Equatable {
        var index: Int
        var id: String
    }
}

private struct MyMemoryResponse: Decodable {
    struct ResponseData: Decodable {
        var translatedText: String
    }

    var responseData: ResponseData
    var responseStatus: Int
    var responseDetails: String?
}
