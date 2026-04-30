import Foundation

enum ImageOverlayTranslationStatus: String, Codable, Equatable {
    case success
    case failed
    case fallbackUsed
    case originalKept
}

struct ImageOverlayTranslationResult: Identifiable, Equatable {
    var segmentID: String
    var sourceText: String
    var translatedText: String
    var lineTranslations: [SegmentLineTranslation]
    var status: ImageOverlayTranslationStatus
    var errorMessage: String?

    var id: String { segmentID }
}

struct SegmentLineTranslation: Identifiable, Codable, Equatable {
    var lineIndex: Int
    var translation: String

    var id: Int { lineIndex }
}

struct ImageOverlayTranslationSummary: Equatable {
    var totalCount: Int
    var successCount: Int
    var fallbackCount: Int
    var originalKeptCount: Int
    var failedCount: Int
}

struct ImageOverlayTranslationBatchEvent: Equatable {
    var batchIndex: Int
    var batchCount: Int
    var results: [ImageOverlayTranslationResult]
}

struct ImageOverlayBatchTranslator: Sendable {
    private let maximumSegmentsPerBatch: Int
    private let cache: ImageOverlayTranslationCache

    init(
        maximumSegmentsPerBatch: Int = 20,
        cache: ImageOverlayTranslationCache
    ) {
        self.maximumSegmentsPerBatch = max(1, maximumSegmentsPerBatch)
        self.cache = cache
    }

    func translate(
        segments: [OverlaySegment],
        targetLanguage: String,
        provider: any TranslationProvider,
        modelName: String,
        translationMode: TranslationMode = .imageOverlay,
        fallbackUsed: Bool = false
    ) async -> [ImageOverlayTranslationResult] {
        guard !segments.isEmpty else {
            return []
        }

        let normalizedModel = normalizedModelName(modelName)
        let contexts = segments.map { segment in
            CachedSegmentContext(
                segment: segment,
                cacheKey: .init(
                    sourceText: normalizedSourceText(segment.sourceText),
                    targetLanguage: targetLanguage,
                    providerID: provider.id.rawValue,
                    modelName: normalizedModel,
                    translationMode: translationMode
                )
            )
        }
        let cachedEntries = await cache.values(for: contexts.map(\.cacheKey))

        var resultsBySegmentID: [String: ImageOverlayTranslationResult] = [:]
        var uniqueMissesByKey: [ImageOverlayTranslationCache.Key: CachedSegmentContext] = [:]
        var hitCount = 0
        var missCount = 0

        for context in contexts {
            let segmentID = context.segment.id
            if !context.segment.shouldTranslate {
                hitCount += 1
                resultsBySegmentID[segmentID] = successResult(
                    for: context.segment,
                    translatedText: context.segment.sourceText,
                    lineTranslations: sourceLineTranslations(for: context.segment),
                    fallbackUsed: fallbackUsed
                )
                continue
            }

            if let cached = cachedEntries[context.cacheKey] {
                hitCount += 1
                resultsBySegmentID[segmentID] = successResult(
                    for: context.segment,
                    translatedText: cached.translatedText,
                    lineTranslations: cached.lineTranslations,
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
            return segments.compactMap { resultsBySegmentID[$0.id] }
        }

        let translatedMisses: [ImageOverlayTranslationResult]
        if let promptProvider = provider as? any PromptCompletionProvider {
            translatedMisses = await translateInBatches(
                segments: missedContexts.map(\.segment),
                targetLanguage: targetLanguage,
                promptProvider: promptProvider,
                providerLabel: provider.displayName,
                modelName: normalizedModel,
                translationMode: translationMode,
                fallbackUsed: fallbackUsed
            )
        } else {
            translatedMisses = await translateSequentially(
                segments: missedContexts.map(\.segment),
                targetLanguage: targetLanguage,
                provider: provider,
                translationMode: translationMode,
                fallbackUsed: fallbackUsed
            )
        }

        var translatedByKey: [ImageOverlayTranslationCache.Key: ImageOverlayTranslationResult] = [:]
        let missedContextBySegmentID = Dictionary(
            uniqueKeysWithValues: missedContexts.map { ($0.segment.id, $0) }
        )

        for result in translatedMisses {
            guard let context = missedContextBySegmentID[result.segmentID] else {
                continue
            }

            translatedByKey[context.cacheKey] = result
            if result.status == .success || result.status == .fallbackUsed {
                await cache.insert(
                    translatedText: result.translatedText,
                    lineTranslations: result.lineTranslations,
                    for: context.cacheKey
                )
            }
        }

        for context in contexts where resultsBySegmentID[context.segment.id] == nil {
            if let sharedResult = translatedByKey[context.cacheKey] {
                resultsBySegmentID[context.segment.id] = ImageOverlayTranslationResult(
                    segmentID: context.segment.id,
                    sourceText: context.segment.sourceText,
                    translatedText: sharedResult.translatedText,
                    lineTranslations: sharedResult.lineTranslations,
                    status: sharedResult.status,
                    errorMessage: sharedResult.errorMessage
                )
            } else {
                resultsBySegmentID[context.segment.id] = failureResult(
                    for: context.segment,
                    errorMessage: "未获得该语义段的批量翻译结果。"
                )
            }
        }

        return segments.compactMap { resultsBySegmentID[$0.id] }
    }

    private func translateInBatches(
        segments: [OverlaySegment],
        targetLanguage: String,
        promptProvider: any PromptCompletionProvider,
        providerLabel: String,
        modelName: String,
        translationMode: TranslationMode,
        fallbackUsed: Bool
    ) async -> [ImageOverlayTranslationResult] {
        let batches = makeBatches(from: segments)
        print(
            "image overlay batch translate: provider=\(providerLabel), model=\(modelName.isEmpty ? "-" : modelName), segments=\(segments.count), batches=\(batches.count)"
        )

        var output: [ImageOverlayTranslationResult] = []
        output.reserveCapacity(segments.count)
        var shouldAbortRemainingBatches = false

        for (index, batch) in batches.enumerated() {
            if shouldAbortRemainingBatches {
                output.append(contentsOf: failureResults(
                    for: batch,
                    errorMessage: "前一批次请求已超时或失败，已停止当前服务的后续批量翻译。"
                ))
                continue
            }

            let prompt = buildPrompt(
                segments: batch,
                targetLanguage: targetLanguage,
                translationMode: translationMode
            )

            do {
                let rawResponse = try await promptProvider.complete(
                    systemPrompt: prompt.system,
                    userPrompt: prompt.user,
                    temperature: 0.1
                )
                let parseOutcome = parseBatchResponse(
                    rawResponse,
                    expectedSegments: batch,
                    fallbackUsed: fallbackUsed
                )
                switch parseOutcome {
                case .success(let results):
                    output.append(contentsOf: results)
                case .parseFailure(let message):
                    print(
                        "image overlay batch parse fallback: provider=\(providerLabel), model=\(modelName.isEmpty ? "-" : modelName), batch=\(index + 1), size=\(batch.count), reason=\(message)"
                    )
                    shouldAbortRemainingBatches = shouldAbortAfterBatchFailure(message)
                    output.append(contentsOf: failureResults(
                        for: batch,
                        errorMessage: message
                    ))
                }
            } catch {
                print(
                    "image overlay batch failed: provider=\(providerLabel), model=\(modelName.isEmpty ? "-" : modelName), batch=\(index + 1), size=\(batch.count), reason=\(error.localizedDescription)"
                )
                shouldAbortRemainingBatches = shouldAbortAfterBatchFailure(error.localizedDescription)
                output.append(contentsOf: failureResults(
                    for: batch,
                    errorMessage: error.localizedDescription
                ))
            }
        }

        return output
    }

    private func shouldAbortAfterBatchFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("超时") ||
            normalized.contains("timeout") ||
            normalized.contains("429") ||
            normalized.contains("限流") ||
            normalized.contains("额度") ||
            normalized.contains("503") ||
            normalized.contains("high demand") ||
            normalized.contains("network") ||
            normalized.contains("网络")
    }

    private func translateSequentially(
        segments: [OverlaySegment],
        targetLanguage: String,
        provider: any TranslationProvider,
        translationMode: TranslationMode,
        fallbackUsed: Bool
    ) async -> [ImageOverlayTranslationResult] {
        var output: [ImageOverlayTranslationResult] = []
        output.reserveCapacity(segments.count)

        for segment in segments {
            let request = TranslationRequest(
                text: segment.sourceText,
                sourceLanguage: nil,
                targetLanguage: targetLanguage,
                translationMode: translationMode
            )

            do {
                let response = try await provider.translate(request)
                let translatedText = response.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !translatedText.isEmpty else {
                    output.append(failureResult(for: segment, errorMessage: "翻译结果为空。"))
                    continue
                }

                output.append(successResult(
                    for: segment,
                    translatedText: translatedText,
                    lineTranslations: splitTranslationByLineSkeleton(translatedText, for: segment),
                    fallbackUsed: fallbackUsed
                ))
            } catch {
                output.append(failureResult(for: segment, errorMessage: error.localizedDescription))
            }
        }

        return output
    }

    private func buildPrompt(
        segments: [OverlaySegment],
        targetLanguage: String,
        translationMode: TranslationMode
    ) -> PromptBuilder.Prompt {
        switch translationMode {
        case .imageOverlay:
            let inputItems = segments.map {
                PromptBuilder.ImageOverlayBatchSegment(
                    id: $0.id,
                    role: $0.role.rawValue,
                    sourceText: $0.sourceText,
                    lines: $0.lines.enumerated().map { lineIndex, line in
                        PromptBuilder.ImageOverlayBatchLine(
                            lineIndex: lineIndex,
                            text: line.text
                        )
                    },
                    readingOrder: $0.readingOrder
                )
            }
            return PromptBuilder.buildImageOverlayBatchPrompt(
                segments: inputItems,
                targetLanguage: targetLanguage
            )
        default:
            let combinedText = segments
                .map(\.sourceText)
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
        expectedSegments: [OverlaySegment],
        fallbackUsed: Bool
    ) -> BatchParseOutcome {
        let parsedItems = decodeResponseItems(from: rawResponse)
        guard !parsedItems.isEmpty else {
            return .parseFailure("模型未返回可解析的 segment JSON。")
        }

        let expectedSegmentIDs = Set(expectedSegments.map(\.id))
        var translationsByID: [String: BatchOutputItem] = [:]

        for item in parsedItems {
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = item.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  expectedSegmentIDs.contains(id),
                  translationsByID[id] == nil else {
                continue
            }
            translationsByID[id] = BatchOutputItem(
                id: id,
                translation: translation,
                lineTranslations: item.lineTranslations
            )
        }

        let results = expectedSegments.map { segment in
            guard let item = translationsByID[segment.id] else {
                return originalKeptResult(
                    for: segment,
                    errorMessage: "模型未返回该语义段的译文，已保留原文。"
                )
            }

            let cleanedTranslation = item.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTranslation.isEmpty else {
                return originalKeptResult(
                    for: segment,
                    errorMessage: "模型返回了空译文，已保留原文。"
                )
            }

            if translationShouldStayUnchanged(for: segment, candidate: cleanedTranslation) {
                return successResult(
                    for: segment,
                    translatedText: segment.sourceText,
                    lineTranslations: sourceLineTranslations(for: segment),
                    fallbackUsed: fallbackUsed
                )
            }

            return successResult(
                for: segment,
                translatedText: cleanedTranslation,
                lineTranslations: validatedLineTranslations(
                    item.lineTranslations,
                    for: segment
                ) ?? splitTranslationByLineSkeleton(
                    cleanedTranslation,
                    for: segment
                ),
                fallbackUsed: fallbackUsed
            )
        }

        return .success(results)
    }

    private func decodeResponseItems(from rawResponse: String) -> [BatchOutputItem] {
        let candidates = candidateJSONStrings(from: rawResponse)

        for candidate in candidates {
            if let items = decodeBatchItems(candidate), !items.isEmpty {
                return items
            }

            if let repaired = repairedJSONCandidate(from: candidate),
               let items = decodeBatchItems(repaired),
               !items.isEmpty {
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

        if let objectPayload = extractJSONObject(from: rawResponse) {
            candidates.append(objectPayload)
        }

        if let arrayPayload = extractJSONArray(from: rawResponse) {
            candidates.append(arrayPayload)
        }

        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private func decodeBatchItems(_ candidate: String) -> [BatchOutputItem]? {
        guard let data = candidate.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()

        if let wrapped = try? decoder.decode(BatchOutputWrapper.self, from: data) {
            return wrapped.translations ?? wrapped.results ?? wrapped.items
        }

        if let items = try? decoder.decode([BatchOutputItem].self, from: data) {
            return items
        }

        if let item = try? decoder.decode(BatchOutputItem.self, from: data) {
            return [item]
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

    private func extractJSONObject(from rawResponse: String) -> String? {
        guard let start = rawResponse.firstIndex(of: "{"),
              let end = rawResponse.lastIndex(of: "}"),
              start <= end else {
            return nil
        }

        return String(rawResponse[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractJSONArray(from rawResponse: String) -> String? {
        guard let start = rawResponse.firstIndex(of: "["),
              let end = rawResponse.lastIndex(of: "]"),
              start <= end else {
            return nil
        }

        return String(rawResponse[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func repairedJSONCandidate(from candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        var repaired = trimmed
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "\"")
            .replacingOccurrences(of: "’", with: "\"")

        repaired = repaired.replacingOccurrences(
            of: #",(\s*[\]}])"#,
            with: "$1",
            options: .regularExpression
        )

        if repaired.first == "[" {
            repaired = #"{"translations": \#(repaired)}"#
        }

        return repaired == trimmed ? nil : repaired
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

    private func makeBatches(from segments: [OverlaySegment]) -> [[OverlaySegment]] {
        stride(from: 0, to: segments.count, by: maximumSegmentsPerBatch).map { start in
            Array(segments[start..<min(start + maximumSegmentsPerBatch, segments.count)])
        }
    }

    private func successResult(
        for segment: OverlaySegment,
        translatedText: String,
        lineTranslations: [SegmentLineTranslation]? = nil,
        fallbackUsed: Bool
    ) -> ImageOverlayTranslationResult {
        ImageOverlayTranslationResult(
            segmentID: segment.id,
            sourceText: segment.sourceText,
            translatedText: translatedText,
            lineTranslations: lineTranslations ?? splitTranslationByLineSkeleton(translatedText, for: segment),
            status: fallbackUsed ? .fallbackUsed : .success,
            errorMessage: nil
        )
    }

    private func failureResults(
        for segments: [OverlaySegment],
        errorMessage: String
    ) -> [ImageOverlayTranslationResult] {
        segments.map { failureResult(for: $0, errorMessage: errorMessage) }
    }

    private func failureResult(
        for segment: OverlaySegment,
        errorMessage: String
    ) -> ImageOverlayTranslationResult {
        ImageOverlayTranslationResult(
            segmentID: segment.id,
            sourceText: segment.sourceText,
            translatedText: segment.sourceText,
            lineTranslations: sourceLineTranslations(for: segment),
            status: .failed,
            errorMessage: errorMessage
        )
    }

    private func originalKeptResult(
        for segment: OverlaySegment,
        errorMessage: String
    ) -> ImageOverlayTranslationResult {
        ImageOverlayTranslationResult(
            segmentID: segment.id,
            sourceText: segment.sourceText,
            translatedText: segment.sourceText,
            lineTranslations: sourceLineTranslations(for: segment),
            status: .originalKept,
            errorMessage: errorMessage
        )
    }

    private func validatedLineTranslations(
        _ candidate: [BatchOutputLineItem]?,
        for segment: OverlaySegment
    ) -> [SegmentLineTranslation]? {
        guard let candidate, !candidate.isEmpty else {
            return nil
        }

        let expectedCount = max(segment.lines.count, 1)
        var seen = Set<Int>()
        var output: [SegmentLineTranslation] = []

        for item in candidate {
            let cleaned = item.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard item.lineIndex >= 0,
                  item.lineIndex < expectedCount,
                  !cleaned.isEmpty,
                  !seen.contains(item.lineIndex) else {
                return nil
            }

            seen.insert(item.lineIndex)
            output.append(
                SegmentLineTranslation(
                    lineIndex: item.lineIndex,
                    translation: cleaned
                )
            )
        }

        guard output.count == expectedCount else {
            return nil
        }

        return output.sorted { $0.lineIndex < $1.lineIndex }
    }

    private func sourceLineTranslations(
        for segment: OverlaySegment
    ) -> [SegmentLineTranslation] {
        segment.lines.enumerated().map { index, line in
            SegmentLineTranslation(
                lineIndex: index,
                translation: line.text
            )
        }
    }

    private func splitTranslationByLineSkeleton(
        _ translation: String,
        for segment: OverlaySegment
    ) -> [SegmentLineTranslation] {
        let cleaned = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return sourceLineTranslations(for: segment)
        }

        let expectedLineCount = max(segment.lines.count, 1)
        guard expectedLineCount > 1 else {
            return [SegmentLineTranslation(lineIndex: 0, translation: cleaned)]
        }

        let explicitLines = cleaned
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if explicitLines.count == expectedLineCount {
            return explicitLines.enumerated().map { index, value in
                SegmentLineTranslation(lineIndex: index, translation: value)
            }
        }

        if explicitLines.count > expectedLineCount {
            var merged: [SegmentLineTranslation] = []
            for index in 0..<expectedLineCount {
                let value: String
                if index < expectedLineCount - 1 {
                    value = explicitLines[index]
                } else {
                    value = explicitLines[index...].joined(separator: " ")
                }
                merged.append(SegmentLineTranslation(lineIndex: index, translation: value))
            }
            return merged
        }

        if containsCJK(cleaned) {
            return proportionalCharacterSplit(cleaned, segment: segment)
        }

        return proportionalWordSplit(cleaned, segment: segment)
    }

    private func proportionalWordSplit(
        _ translation: String,
        segment: OverlaySegment
    ) -> [SegmentLineTranslation] {
        let words = translation
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !words.isEmpty else {
            return sourceLineTranslations(for: segment)
        }

        let weights = segment.lines.map { max(compactLength($0.text), 1) }
        let ranges = proportionalRanges(total: words.count, weights: weights)

        return ranges.enumerated().map { index, range in
            let value = range.isEmpty
                ? words[min(index, words.count - 1)]
                : words[range].joined(separator: " ")
            return SegmentLineTranslation(lineIndex: index, translation: value)
        }
    }

    private func proportionalCharacterSplit(
        _ translation: String,
        segment: OverlaySegment
    ) -> [SegmentLineTranslation] {
        let characters = Array(translation)
        guard !characters.isEmpty else {
            return sourceLineTranslations(for: segment)
        }

        let weights = segment.lines.map { max(compactLength($0.text), 1) }
        let ranges = proportionalRanges(total: characters.count, weights: weights)

        return ranges.enumerated().map { index, range in
            let value: String
            if range.isEmpty {
                value = String(characters[min(index, characters.count - 1)])
            } else {
                value = String(characters[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return SegmentLineTranslation(
                lineIndex: index,
                translation: value.isEmpty ? translation : value
            )
        }
    }

    private func proportionalRanges(
        total: Int,
        weights: [Int]
    ) -> [Range<Int>] {
        guard total > 0, !weights.isEmpty else {
            return []
        }

        let totalWeight = max(weights.reduce(0, +), 1)
        var ranges: [Range<Int>] = []
        var cursor = 0

        for index in weights.indices {
            let remainingLines = weights.count - index
            if index == weights.count - 1 {
                ranges.append(cursor..<total)
                break
            }

            let proportional = Int(round(Double(total) * Double(weights[index]) / Double(totalWeight)))
            let minimumRemaining = remainingLines - 1
            let available = max(total - cursor - minimumRemaining, 1)
            let count = max(1, min(proportional, available))
            ranges.append(cursor..<(cursor + count))
            cursor += count
        }

        if ranges.count < weights.count {
            ranges.append(cursor..<total)
        }

        return ranges
    }

    private func compactLength(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }

    private func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
                (0x3400...0x4DBF).contains(Int(scalar.value))
        }
    }

    private func translationShouldStayUnchanged(
        for segment: OverlaySegment,
        candidate _: String
    ) -> Bool {
        return [.code, .url, .number].contains(segment.role)
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
    var lineTranslations: [BatchOutputLineItem]?
}

private struct BatchOutputLineItem: Codable {
    var lineIndex: Int
    var translation: String
}

private enum BatchParseOutcome {
    case success([ImageOverlayTranslationResult])
    case parseFailure(String)
}

private struct BatchOutputWrapper: Codable {
    var translations: [BatchOutputItem]?
    var results: [BatchOutputItem]?
    var items: [BatchOutputItem]?
}

private struct CachedSegmentContext {
    var segment: OverlaySegment
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
