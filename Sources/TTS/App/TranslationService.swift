import AppKit
import Foundation

@MainActor
final class TranslationService {
    private let providerFactory: TranslationProviderFactory
    private let imageOverlayBatchTranslator: ImageOverlayBatchTranslator

    init(
        providerFactory: TranslationProviderFactory,
        imageOverlayTranslationCache: ImageOverlayTranslationCache = ImageOverlayTranslationCache()
    ) {
        self.providerFactory = providerFactory
        self.imageOverlayBatchTranslator = ImageOverlayBatchTranslator(
            maximumSegmentsPerBatch: 6,
            cache: imageOverlayTranslationCache
        )
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
        translationMode: TranslationMode? = nil,
        scenario: TranslationScenario
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

        return try await translateWithFallback(request, scenario: scenario)
    }

    func translate(
        text: String,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        translationMode: TranslationMode? = nil,
        scenario: TranslationScenario,
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
            translationMode: finalTranslationMode,
            scenario: scenario
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

        return item
    }

    func translateImageOverlaySegments(
        _ segments: [OverlaySegment],
        targetLanguage: String? = nil
    ) async throws -> [ImageOverlayTranslationResult] {
        var output: [ImageOverlayTranslationResult] = []
        for try await event in translateImageOverlaySegmentsIncrementally(
            segments,
            targetLanguage: targetLanguage,
            batchSize: 6
        ) {
            output.append(contentsOf: event.results)
        }
        return output
    }

    func translateImageOverlaySegmentsIncrementally(
        _ segments: [OverlaySegment],
        targetLanguage: String? = nil,
        batchSize: Int = 6
    ) -> AsyncThrowingStream<ImageOverlayTranslationBatchEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let validSegments = segments.filter { !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    guard !validSegments.isEmpty else {
                        continuation.finish()
                        return
                    }

                    let batches = makeImageOverlayIncrementalBatches(
                        from: validSegments,
                        batchSize: batchSize
                    )
                    let maximumConcurrentBatches = min(2, batches.count)
                    try await withThrowingTaskGroup(of: ImageOverlayTranslationBatchEvent.self) { group in
                        var nextBatchIndex = 0

                        while nextBatchIndex < maximumConcurrentBatches {
                            let index = nextBatchIndex
                            let batch = batches[index]
                            nextBatchIndex += 1
                            group.addTask { [weak self] in
                                guard let self else {
                                    throw CancellationError()
                                }
                                try Task.checkCancellation()
                                let results = try await self.translateImageOverlaySegmentBatch(
                                    batch,
                                    targetLanguage: targetLanguage
                                )
                                return ImageOverlayTranslationBatchEvent(
                                    batchIndex: index,
                                    batchCount: batches.count,
                                    results: results
                                )
                            }
                        }

                        while let event = try await group.next() {
                            continuation.yield(event)

                            if nextBatchIndex < batches.count {
                                let index = nextBatchIndex
                                let batch = batches[index]
                                nextBatchIndex += 1
                                group.addTask { [weak self] in
                                    guard let self else {
                                        throw CancellationError()
                                    }
                                    try Task.checkCancellation()
                                    let results = try await self.translateImageOverlaySegmentBatch(
                                        batch,
                                        targetLanguage: targetLanguage
                                    )
                                    return ImageOverlayTranslationBatchEvent(
                                        batchIndex: index,
                                        batchCount: batches.count,
                                        results: results
                                    )
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func translateImageOverlaySegmentBatch(
        _ segments: [OverlaySegment],
        targetLanguage: String? = nil
    ) async throws -> [ImageOverlayTranslationResult] {
        let validSegments = segments.filter { !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validSegments.isEmpty else {
            return []
        }

        let requestedTargetLanguage = targetLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTargetLanguage = requestedTargetLanguage?.isEmpty == false
            ? requestedTargetLanguage!
            : providerFactory.targetLanguage
        let providerPlan = try resolveProviderPlan(
            scenario: .imageOverlay,
            translationMode: .imageOverlay
        )

        let primaryResults = await translateImageOverlayBatch(
            validSegments,
            targetLanguage: finalTargetLanguage,
            config: providerPlan.primaryConfig,
            modelOverride: providerPlan.primaryModelOverride,
            fallbackUsed: false,
            scenario: .imageOverlay,
            attemptLabel: "primary"
        )

        let failedSegmentIDs = Set(
            primaryResults
                .filter { $0.status == .failed }
                .map(\.segmentID)
        )
        let failedSegments = validSegments.filter { failedSegmentIDs.contains($0.id) }

        guard let fallbackPlan = providerPlan.fallback,
              !failedSegments.isEmpty,
              !sameProviderAndModel(
                lhsProvider: providerPlan.primaryConfig.id,
                lhsModel: providerPlan.primaryModelOverride ?? providerPlan.primaryConfig.model,
                rhsProvider: fallbackPlan.config.id,
                rhsModel: fallbackPlan.modelOverride ?? fallbackPlan.config.model
              ) else {
            let finalized = primaryResults.map(finalizeImageOverlayResult)
            logImageOverlaySummary(
                scenario: .imageOverlay,
                batchCount: imageOverlayBatchCount(for: validSegments.count),
                results: finalized
            )
            return finalized
        }

        let firstFailureKind = primaryResults
            .first(where: { $0.status == .failed })
            .map { classifyBatchFailureMessage($0.errorMessage) } ?? .providerError
        print(
            "translation scenario fallback: scenario=imageOverlay, primary=\(providerPlan.primaryConfig.id.rawValue)/\((providerPlan.primaryModelOverride ?? providerPlan.primaryConfig.model) ?? "-"), fallback=\(fallbackPlan.config.id.rawValue)/\((fallbackPlan.modelOverride ?? fallbackPlan.config.model) ?? "-"), errorType=\(firstFailureKind.rawValue)"
        )

        let fallbackResults = await translateImageOverlayBatch(
            failedSegments,
            targetLanguage: finalTargetLanguage,
            config: fallbackPlan.config,
            modelOverride: fallbackPlan.modelOverride,
            fallbackUsed: true,
            scenario: .imageOverlay,
            attemptLabel: "fallback"
        )

        let fallbackByID = Dictionary(uniqueKeysWithValues: fallbackResults.map { ($0.segmentID, $0) })
        let finalized = primaryResults.map { result in
            guard result.status == .failed,
                  let fallbackResult = fallbackByID[result.segmentID] else {
                return finalizeImageOverlayResult(result)
            }

            return finalizeImageOverlayResult(fallbackResult)
        }
        logImageOverlaySummary(
            scenario: .imageOverlay,
            batchCount: imageOverlayBatchCount(for: validSegments.count),
            results: finalized
        )
        return finalized
    }

    private func translateWithFallback(
        _ request: TranslationRequest,
        scenario: TranslationScenario
    ) async throws -> TranslationResponse {
        let providerPlan = try resolveProviderPlan(
            scenario: scenario,
            translationMode: request.translationMode
        )

        var failureKinds: [TranslationFailureKind] = []
        var fallbackAttempted = false

        do {
            return try await runAttempt(
                request,
                config: providerPlan.primaryConfig,
                modelOverride: providerPlan.primaryModelOverride,
                attemptNumber: 1,
                note: "primary",
                scenario: scenario
            )
        } catch {
            let firstKind = classify(error)
            failureKinds.append(firstKind)

            if let fallbackPlan = providerPlan.fallback,
               !sameProviderAndModel(
                lhsProvider: providerPlan.primaryConfig.id,
                lhsModel: providerPlan.primaryModelOverride ?? providerPlan.primaryConfig.model,
                rhsProvider: fallbackPlan.config.id,
                rhsModel: fallbackPlan.modelOverride ?? fallbackPlan.config.model
               ) {
                do {
                    fallbackAttempted = true
                    print(
                        "translation scenario fallback: scenario=\(scenario.rawValue), primary=\(providerPlan.primaryConfig.id.rawValue)/\((providerPlan.primaryModelOverride ?? providerPlan.primaryConfig.model) ?? "-"), fallback=\(fallbackPlan.config.id.rawValue)/\((fallbackPlan.modelOverride ?? fallbackPlan.config.model) ?? "-"), errorType=\(firstKind.rawValue)"
                    )
                    return try await runAttempt(
                        request,
                        config: fallbackPlan.config,
                        modelOverride: fallbackPlan.modelOverride?.isEmpty == false ? fallbackPlan.modelOverride : nil,
                        attemptNumber: 2,
                        note: "fallback",
                        scenario: scenario
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
        note: String,
        scenario: TranslationScenario
    ) async throws -> TranslationResponse {
        let adjustedConfig = tunedProviderConfig(config, for: scenario)
        let providerLabel = adjustedConfig.displayName
        let modelLabel = modelOverride ?? adjustedConfig.model ?? "-"
        print("translation provider attempt[\(attemptNumber)] \(note): provider=\(providerLabel), model=\(modelLabel)")

        let provider = try providerFactory.makeProvider(config: adjustedConfig, modelOverride: modelOverride)
        do {
            let response = try await provider.translate(request)
            print("translation provider success[\(attemptNumber)]: provider=\(providerLabel)")
            return response
        } catch {
            print("translation provider failed[\(attemptNumber)]: provider=\(providerLabel), kind=\(classify(error).rawValue), reason=\(error.localizedDescription)")
            throw error
        }
    }

    private func resolveProviderPlan(
        scenario: TranslationScenario,
        translationMode: TranslationMode
    ) throws -> ResolvedScenarioProviderPlan {
        guard let primaryConfig = providerFactory.defaultProviderConfig() else {
            throw TranslationProviderError.providerMessage("没有已启用且已接入的翻译服务。")
        }

        let fallbackPlan: ResolvedScenarioProviderPlan.FallbackPlan? = {
            guard providerFactory.fallbackEnabled,
                  let config = providerFactory.fallbackProviderConfig(),
                  config.id != primaryConfig.id else {
                return nil
            }
            return .init(config: config, modelOverride: providerFactory.fallbackModel)
        }()

        if translationMode == .ocrCleanup,
           !providerFactory.supportsTranslationModePrompts(providerID: primaryConfig.id) {
            guard let fallbackPlan,
                  providerFactory.supportsTranslationModePrompts(
                      providerID: fallbackPlan.config.id
                  ) else {
                throw TranslationProviderError.providerMessage(
                    "默认和备用翻译服务都不支持 OCR AI 修复，请选择支持 Prompt 的 AI 模型。"
                )
            }

            print(
                "translation provider resolve: scenario=\(scenario.rawValue), primary=\(fallbackPlan.config.id.rawValue), fallback=-, promotedFallback=true"
            )
            return ResolvedScenarioProviderPlan(
                primaryConfig: fallbackPlan.config,
                primaryModelOverride: fallbackPlan.modelOverride,
                fallback: nil
            )
        }

        print(
            "translation provider resolve: scenario=\(scenario.rawValue), primary=\(primaryConfig.id.rawValue), fallback=\(fallbackPlan?.config.id.rawValue ?? "-")"
        )

        return ResolvedScenarioProviderPlan(
            primaryConfig: primaryConfig,
            primaryModelOverride: nil,
            fallback: fallbackPlan
        )
    }

    private func translateImageOverlayBatch(
        _ segments: [OverlaySegment],
        targetLanguage: String,
        config: ProviderConfig,
        modelOverride: String?,
        fallbackUsed: Bool,
        scenario: TranslationScenario,
        attemptLabel: String
    ) async -> [ImageOverlayTranslationResult] {
        let modelLabel = modelOverride ?? config.model ?? "-"
        print(
            "translation imageOverlay attempt: scenario=\(scenario.rawValue), provider=\(config.displayName), model=\(modelLabel), segments=\(segments.count), note=\(attemptLabel)"
        )

        do {
            let provider = try providerFactory.makeProvider(
                config: tunedProviderConfig(config, for: scenario),
                modelOverride: modelOverride
            )
            return await imageOverlayBatchTranslator.translate(
                segments: segments,
                targetLanguage: targetLanguage,
                provider: provider,
                modelName: modelLabel,
                translationMode: .imageOverlay,
                fallbackUsed: fallbackUsed
            )
        } catch {
            let kind = classify(error)
            print(
                "translation imageOverlay setup failed: scenario=\(scenario.rawValue), provider=\(config.displayName), model=\(modelLabel), kind=\(kind.rawValue), reason=\(error.localizedDescription)"
            )
            return segments.map { segment in
                ImageOverlayTranslationResult(
                    segmentID: segment.id,
                    sourceText: segment.sourceText,
                    translatedText: segment.sourceText,
                    lineTranslations: segment.lines.enumerated().map { index, line in
                        SegmentLineTranslation(lineIndex: index, translation: line.text)
                    },
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    private func tunedProviderConfig(
        _ config: ProviderConfig,
        for scenario: TranslationScenario
    ) -> ProviderConfig {
        var next = config

        switch scenario {
        case .imageOverlay:
            break
        case .screenshot:
            next.timeout = min(next.timeout, 15)
        case .selection, .input, .ocrCleanup:
            break
        }

        return next
    }

    private func finalFailureMessage(
        failureKinds: [TranslationFailureKind],
        fallbackAttempted: Bool
    ) -> String {
        if failureKinds.contains(.rateLimited) {
            return fallbackAttempted
                ? "主翻译服务请求失败，全局备用服务也未成功。请检查服务商额度或限流状态。"
                : "当前服务商请求失败，请检查服务商额度或限流状态。"
        }

        if failureKinds.contains(.invalidAPIKey) {
            return fallbackAttempted
                ? "主翻译服务请求失败，全局备用服务也未成功。请检查 API Key、模型名称、网络连接或服务商额度。"
                : "当前服务商请求失败，请检查 API Key、网络连接或服务商额度。"
        }

        return fallbackAttempted
            ? "主翻译服务请求失败，全局备用服务也未成功。请检查 API Key、模型名称、网络连接或服务商额度。"
            : "当前服务商请求失败。请检查 API Key、网络连接或服务商额度。"
    }

    private func sameProviderAndModel(
        lhsProvider: TranslationProviderID,
        lhsModel: String?,
        rhsProvider: TranslationProviderID,
        rhsModel: String?
    ) -> Bool {
        guard lhsProvider == rhsProvider else {
            return false
        }

        return normalizedModelName(lhsModel) == normalizedModelName(rhsModel)
    }

    private func normalizedModelName(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    private func classifyBatchFailureMessage(_ message: String?) -> TranslationFailureKind {
        let normalized = message?.lowercased() ?? ""
        if normalized.contains("api key") || normalized.contains("认证失败") {
            return .invalidAPIKey
        }
        if normalized.contains("额度") || normalized.contains("限流") || normalized.contains("429") {
            return .rateLimited
        }
        if normalized.contains("超时") || normalized.contains("timeout") {
            return .timeout
        }
        if normalized.contains("网络") || normalized.contains("network") {
            return .networkError
        }
        if normalized.contains("为空") || normalized.contains("json") {
            return .emptyResult
        }
        return .providerError
    }

    private func finalizeImageOverlayResult(
        _ result: ImageOverlayTranslationResult
    ) -> ImageOverlayTranslationResult {
        guard result.status == .failed else {
            return result
        }

        var next = result
        next.status = .originalKept
        next.translatedText = result.sourceText
        return next
    }

    private func imageOverlayBatchCount(for totalSegments: Int) -> Int {
        guard totalSegments > 0 else {
            return 0
        }

        return Int(ceil(Double(totalSegments) / 6.0))
    }

    private func makeImageOverlayIncrementalBatches(
        from segments: [OverlaySegment],
        batchSize: Int
    ) -> [[OverlaySegment]] {
        let resolvedBatchSize = max(batchSize, 1)
        return stride(from: 0, to: segments.count, by: resolvedBatchSize).map { start in
            Array(segments[start..<min(start + resolvedBatchSize, segments.count)])
        }
    }

    private func logImageOverlaySummary(
        scenario: TranslationScenario,
        batchCount: Int,
        results: [ImageOverlayTranslationResult]
    ) {
        let summary = results.imageOverlaySummary
        let errorTypes = Set(
            results
                .compactMap { result -> TranslationFailureKind? in
                    guard result.status == .failed || result.status == .originalKept else {
                        return nil
                    }
                    return classifyBatchFailureMessage(result.errorMessage)
                }
                .map(\.rawValue)
        )
        .sorted()
        .joined(separator: ",")

        print(
            "translation imageOverlay summary: scenario=\(scenario.rawValue), batchCount=\(batchCount), successCount=\(summary.successCount), failedCount=\(summary.failedCount), fallbackCount=\(summary.fallbackCount), originalKeptCount=\(summary.originalKeptCount), errorType=\(errorTypes.isEmpty ? "-" : errorTypes)"
        )
    }

}

private struct ResolvedScenarioProviderPlan {
    struct FallbackPlan {
        var config: ProviderConfig
        var modelOverride: String?
    }

    var primaryConfig: ProviderConfig
    var primaryModelOverride: String?
    var fallback: FallbackPlan?
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
