import Foundation

enum ImageOverlayTranslationStatus: String, Codable, Equatable {
    case success
    case failed
    case fallbackUsed
    case originalKept
}

struct ImageOverlayTranslationResult: Identifiable, Equatable {
    var blockID: String
    var sourceText: String
    var translatedText: String
    var status: ImageOverlayTranslationStatus
    var errorMessage: String?

    var id: String { blockID }
}

struct ImageOverlayTranslationSummary: Equatable {
    var totalCount: Int
    var successCount: Int
    var fallbackCount: Int
    var originalKeptCount: Int
    var failedCount: Int
}

struct ImageOverlayBatchTranslator: Sendable {
    private let maximumBlocksPerBatch: Int
    private let cache: ImageOverlayTranslationCache

    init(
        maximumBlocksPerBatch: Int = 20,
        cache: ImageOverlayTranslationCache
    ) {
        self.maximumBlocksPerBatch = max(1, maximumBlocksPerBatch)
        self.cache = cache
    }

    func translate(
        blocks: [OCRTextBlock],
        targetLanguage: String,
        provider: any TranslationProvider,
        modelName: String,
        translationMode: TranslationMode = .imageOverlay,
        fallbackUsed: Bool = false
    ) async -> [ImageOverlayTranslationResult] {
        guard !blocks.isEmpty else {
            return []
        }

        let normalizedModel = normalizedModelName(modelName)
        let contexts = blocks.map { block in
            CachedBlockContext(
                block: block,
                cacheKey: .init(
                    sourceText: normalizedSourceText(block.text),
                    targetLanguage: targetLanguage,
                    providerID: provider.id.rawValue,
                    modelName: normalizedModel,
                    translationMode: translationMode
                )
            )
        }
        let cachedEntries = await cache.values(for: contexts.map(\.cacheKey))

        var resultsByBlockID: [String: ImageOverlayTranslationResult] = [:]
        var uniqueMissesByKey: [ImageOverlayTranslationCache.Key: CachedBlockContext] = [:]
        var hitCount = 0
        var missCount = 0

        for context in contexts {
            let blockID = context.block.id.uuidString
            if let cached = cachedEntries[context.cacheKey] {
                hitCount += 1
                resultsByBlockID[blockID] = successResult(
                    for: context.block,
                    translatedText: cached.translatedText,
                    fallbackUsed: fallbackUsed
                )
            } else {
                missCount += 1
                if uniqueMissesByKey[context.cacheKey] == nil {
                    uniqueMissesByKey[context.cacheKey] = context
                }
            }
        }

        print(
            "image overlay cache: provider=\(provider.displayName), model=\(normalizedModel.isEmpty ? "-" : normalizedModel), hitCount=\(hitCount), missCount=\(missCount)"
        )

        let missedContexts = Array(uniqueMissesByKey.values)
        guard !missedContexts.isEmpty else {
            return blocks.compactMap { resultsByBlockID[$0.id.uuidString] }
        }

        let translatedMisses: [ImageOverlayTranslationResult]
        if let promptProvider = provider as? any PromptCompletionProvider {
            translatedMisses = await translateInBatches(
                blocks: missedContexts.map(\.block),
                targetLanguage: targetLanguage,
                provider: promptProvider,
                providerLabel: provider.displayName,
                modelName: normalizedModel,
                translationMode: translationMode,
                fallbackUsed: fallbackUsed
            )
        } else {
            translatedMisses = await translateSequentially(
                blocks: missedContexts.map(\.block),
                targetLanguage: targetLanguage,
                provider: provider,
                translationMode: translationMode,
                fallbackUsed: fallbackUsed
            )
        }

        var translatedByKey: [ImageOverlayTranslationCache.Key: ImageOverlayTranslationResult] = [:]
        let missedContextByBlockID = Dictionary(
            uniqueKeysWithValues: missedContexts.map { ($0.block.id.uuidString, $0) }
        )

        for result in translatedMisses {
            guard let context = missedContextByBlockID[result.blockID] else {
                continue
            }

            translatedByKey[context.cacheKey] = result
            if result.status == .success || result.status == .fallbackUsed {
                await cache.insert(result.translatedText, for: context.cacheKey)
            }
        }

        for context in contexts where resultsByBlockID[context.block.id.uuidString] == nil {
            if let sharedResult = translatedByKey[context.cacheKey] {
                resultsByBlockID[context.block.id.uuidString] = ImageOverlayTranslationResult(
                    blockID: context.block.id.uuidString,
                    sourceText: context.block.text,
                    translatedText: sharedResult.translatedText,
                    status: sharedResult.status,
                    errorMessage: sharedResult.errorMessage
                )
            } else {
                resultsByBlockID[context.block.id.uuidString] = failureResult(
                    for: context.block,
                    errorMessage: "未获得该文本块的批量翻译结果。"
                )
            }
        }

        return blocks.compactMap { resultsByBlockID[$0.id.uuidString] }
    }

    private func translateInBatches(
        blocks: [OCRTextBlock],
        targetLanguage: String,
        provider: any PromptCompletionProvider,
        providerLabel: String,
        modelName: String,
        translationMode: TranslationMode,
        fallbackUsed: Bool
    ) async -> [ImageOverlayTranslationResult] {
        let batches = makeBatches(from: blocks)
        print(
            "image overlay batch translate: provider=\(providerLabel), model=\(modelName.isEmpty ? "-" : modelName), blocks=\(blocks.count), batches=\(batches.count)"
        )

        var output: [ImageOverlayTranslationResult] = []
        output.reserveCapacity(blocks.count)

        for (index, batch) in batches.enumerated() {
            let prompt = buildPrompt(
                blocks: batch,
                targetLanguage: targetLanguage,
                translationMode: translationMode
            )

            do {
                let rawResponse = try await provider.complete(
                    systemPrompt: prompt.system,
                    userPrompt: prompt.user,
                    temperature: 0.1
                )
                let results = parseBatchResponse(
                    rawResponse,
                    expectedBlocks: batch,
                    fallbackUsed: fallbackUsed
                )
                output.append(contentsOf: results)
            } catch {
                print(
                    "image overlay batch failed: provider=\(providerLabel), model=\(modelName.isEmpty ? "-" : modelName), batch=\(index + 1), size=\(batch.count), reason=\(error.localizedDescription)"
                )
                output.append(contentsOf: failureResults(
                    for: batch,
                    errorMessage: error.localizedDescription
                ))
            }
        }

        return output
    }

    private func translateSequentially(
        blocks: [OCRTextBlock],
        targetLanguage: String,
        provider: any TranslationProvider,
        translationMode: TranslationMode,
        fallbackUsed: Bool
    ) async -> [ImageOverlayTranslationResult] {
        var output: [ImageOverlayTranslationResult] = []
        output.reserveCapacity(blocks.count)

        for block in blocks {
            let request = TranslationRequest(
                text: block.text,
                sourceLanguage: nil,
                targetLanguage: targetLanguage,
                translationMode: translationMode
            )

            do {
                let response = try await provider.translate(request)
                let translatedText = response.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !translatedText.isEmpty else {
                    output.append(failureResult(for: block, errorMessage: "翻译结果为空。"))
                    continue
                }

                output.append(successResult(
                    for: block,
                    translatedText: translatedText,
                    fallbackUsed: fallbackUsed
                ))
            } catch {
                output.append(failureResult(for: block, errorMessage: error.localizedDescription))
            }
        }

        return output
    }

    private func buildPrompt(
        blocks: [OCRTextBlock],
        targetLanguage: String,
        translationMode: TranslationMode
    ) -> PromptBuilder.Prompt {
        switch translationMode {
        case .imageOverlay:
            let inputItems = blocks.map {
                PromptBuilder.ImageOverlayBatchBlock(
                    id: $0.id.uuidString,
                    text: $0.text
                )
            }
            return PromptBuilder.buildImageOverlayBatchPrompt(
                blocks: inputItems,
                targetLanguage: targetLanguage
            )
        default:
            let combinedText = blocks
                .map(\.text)
                .joined(separator: "\n")
            return PromptBuilder.build(
                mode: translationMode,
                sourceText: combinedText,
                targetLanguage: targetLanguage
            )
        }
    }

    private func parseBatchResponse(
        _ rawResponse: String,
        expectedBlocks: [OCRTextBlock],
        fallbackUsed: Bool
    ) -> [ImageOverlayTranslationResult] {
        let parsedItems = decodeResponseItems(from: rawResponse)
        var translationsByID: [String: String] = [:]

        for item in parsedItems {
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = item.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !translation.isEmpty, translationsByID[id] == nil else {
                continue
            }
            translationsByID[id] = translation
        }

        return expectedBlocks.map { block in
            let blockID = block.id.uuidString
            guard let translatedText = translationsByID[blockID] else {
                return failureResult(for: block, errorMessage: "模型未返回该文本块的有效 JSON 译文。")
            }

            return successResult(
                for: block,
                translatedText: translatedText,
                fallbackUsed: fallbackUsed
            )
        }
    }

    private func decodeResponseItems(from rawResponse: String) -> [BatchOutputItem] {
        let candidates = candidateJSONStrings(from: rawResponse)

        for candidate in candidates {
            if let items = decodeBatchItems(candidate), !items.isEmpty {
                return items
            }
        }

        let recovered = recoverObjectItems(from: rawResponse)
        if !recovered.isEmpty {
            return recovered
        }

        return []
    }

    private func candidateJSONStrings(from rawResponse: String) -> [String] {
        var candidates: [String] = []
        let trimmed = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            candidates.append(trimmed)
        }

        if let fenced = extractFencedJSON(from: rawResponse) {
            candidates.append(fenced)
        }

        if let arrayPayload = extractJSONArray(from: rawResponse) {
            candidates.append(arrayPayload)
        }

        return candidates
    }

    private func decodeBatchItems(_ candidate: String) -> [BatchOutputItem]? {
        guard let data = candidate.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()

        if let item = try? decoder.decode(BatchOutputItem.self, from: data) {
            return [item]
        }

        if let items = try? decoder.decode([BatchOutputItem].self, from: data) {
            return items
        }

        if let wrapped = try? decoder.decode(BatchOutputWrapper.self, from: data) {
            return wrapped.translations ?? wrapped.results ?? wrapped.items
        }

        return nil
    }

    private func extractFencedJSON(from rawResponse: String) -> String? {
        let pattern = #"```(?:json)?\s*([\s\S]*?)\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(rawResponse.startIndex..<rawResponse.endIndex, in: rawResponse)
        guard let match = regex.firstMatch(in: rawResponse, range: range),
              match.numberOfRanges > 1,
              let contentRange = Range(match.range(at: 1), in: rawResponse) else {
            return nil
        }

        return String(rawResponse[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractJSONArray(from rawResponse: String) -> String? {
        guard let start = rawResponse.firstIndex(of: "["),
              let end = rawResponse.lastIndex(of: "]"),
              start <= end else {
            return nil
        }

        return String(rawResponse[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recoverObjectItems(from rawResponse: String) -> [BatchOutputItem] {
        let pattern = #"\{[\s\S]*?"id"\s*:\s*"[^"]+"[\s\S]*?"translation"\s*:\s*"[\s\S]*?"[\s\S]*?\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(rawResponse.startIndex..<rawResponse.endIndex, in: rawResponse)
        let matches = regex.matches(in: rawResponse, range: range)
        var items: [BatchOutputItem] = []

        for match in matches {
            guard let matchRange = Range(match.range, in: rawResponse) else {
                continue
            }

            let candidate = String(rawResponse[matchRange])
            if let decoded = decodeBatchItems(candidate)?.first {
                items.append(decoded)
            }
        }

        return items
    }

    private func makeBatches(from blocks: [OCRTextBlock]) -> [[OCRTextBlock]] {
        stride(from: 0, to: blocks.count, by: maximumBlocksPerBatch).map { start in
            Array(blocks[start..<min(start + maximumBlocksPerBatch, blocks.count)])
        }
    }

    private func successResult(
        for block: OCRTextBlock,
        translatedText: String,
        fallbackUsed: Bool
    ) -> ImageOverlayTranslationResult {
        ImageOverlayTranslationResult(
            blockID: block.id.uuidString,
            sourceText: block.text,
            translatedText: translatedText,
            status: fallbackUsed ? .fallbackUsed : .success,
            errorMessage: nil
        )
    }

    private func failureResults(
        for blocks: [OCRTextBlock],
        errorMessage: String
    ) -> [ImageOverlayTranslationResult] {
        blocks.map { failureResult(for: $0, errorMessage: errorMessage) }
    }

    private func failureResult(
        for block: OCRTextBlock,
        errorMessage: String
    ) -> ImageOverlayTranslationResult {
        ImageOverlayTranslationResult(
            blockID: block.id.uuidString,
            sourceText: block.text,
            translatedText: block.text,
            status: .failed,
            errorMessage: errorMessage
        )
    }

    private func normalizedSourceText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedModelName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct BatchOutputItem: Codable {
    var id: String
    var translation: String
}

private struct BatchOutputWrapper: Codable {
    var translations: [BatchOutputItem]?
    var results: [BatchOutputItem]?
    var items: [BatchOutputItem]?
}

private struct CachedBlockContext {
    var block: OCRTextBlock
    var cacheKey: ImageOverlayTranslationCache.Key
}

extension Array where Element == ImageOverlayTranslationResult {
    var imageOverlaySummary: ImageOverlayTranslationSummary {
        ImageOverlayTranslationSummary(
            totalCount: count,
            successCount: filter { $0.status == .success }.count,
            fallbackCount: filter { $0.status == .fallbackUsed }.count,
            originalKeptCount: filter { $0.status == .originalKept }.count,
            failedCount: filter { $0.status == .failed }.count
        )
    }
}
