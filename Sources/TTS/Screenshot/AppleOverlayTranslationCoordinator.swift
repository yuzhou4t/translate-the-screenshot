import Foundation
import NaturalLanguage
import SwiftUI

#if canImport(Translation)
import Translation

private let appleOverlayResultBuilder = ImageOverlayBatchTranslator(
    cache: ImageOverlayTranslationCache()
)

@available(macOS 15.0, *)
struct AppleOverlayTranslationWorkItem: Sendable {
    var id: UUID
    var segments: [OverlaySegment]
    var sourceLanguage: Locale.Language?
    var targetLanguage: Locale.Language
    var targetLanguageIdentifier: String
}

@available(macOS 15.0, *)
@MainActor
final class AppleOverlayTranslationCoordinator: ObservableObject {
    private static let requestTimeoutNanoseconds: UInt64 = 12_000_000_000

    @Published private(set) var requestID: UUID?

    private struct PendingRequest {
        var id: UUID
        var segments: [OverlaySegment]
        var sourceLanguage: Locale.Language?
        var targetLanguage: Locale.Language
        var targetLanguageIdentifier: String
        var continuation: AsyncThrowingStream<ImageOverlayTranslationBatchEvent, Error>.Continuation
        var emittedCount: Int
    }

    private var pendingRequest: PendingRequest?
    private var requestTimeoutTask: Task<Void, Never>?

    var languagePair: (source: Locale.Language?, target: Locale.Language)? {
        guard let pendingRequest else {
            return nil
        }
        return (pendingRequest.sourceLanguage, pendingRequest.targetLanguage)
    }

    func translate(
        segments: [OverlaySegment],
        targetLanguage: String
    ) -> AsyncThrowingStream<ImageOverlayTranslationBatchEvent, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            requestTimeoutTask?.cancel()
            pendingRequest?.continuation.finish(throwing: CancellationError())
            pendingRequest = PendingRequest(
                id: id,
                segments: segments,
                sourceLanguage: Self.detectSourceLanguage(
                    in: segments.filter(\.shouldTranslate)
                ),
                targetLanguage: Self.localeLanguage(for: targetLanguage),
                targetLanguageIdentifier: targetLanguage,
                continuation: continuation,
                emittedCount: 0
            )
            requestID = id
            scheduleRequestTimeout(requestID: id)

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.cancel(requestID: id)
                }
            }
        }
    }

    func currentWorkItem() -> AppleOverlayTranslationWorkItem? {
        guard let request = pendingRequest else {
            return nil
        }
        return AppleOverlayTranslationWorkItem(
            id: request.id,
            segments: request.segments,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage,
            targetLanguageIdentifier: request.targetLanguageIdentifier
        )
    }

    func emit(
        _ result: ImageOverlayTranslationResult,
        requestID: UUID
    ) {
        guard var request = pendingRequest,
              request.id == requestID else {
            return
        }
        request.continuation.yield(
            ImageOverlayTranslationBatchEvent(
                batchIndex: request.emittedCount,
                batchCount: request.segments.count,
                results: [result]
            )
        )
        request.emittedCount += 1
        pendingRequest = request
        scheduleRequestTimeout(requestID: requestID)
    }

    func complete(requestID: UUID) {
        finish(requestID: requestID)
    }

    func fail(_ error: Error, requestID: UUID) {
        finish(throwing: error, requestID: requestID)
    }

    func cancel() {
        guard let requestID else {
            return
        }
        cancel(requestID: requestID)
    }

    private func cancel(requestID: UUID) {
        guard pendingRequest?.id == requestID else {
            return
        }
        finish(throwing: CancellationError(), requestID: requestID)
    }

    private func scheduleRequestTimeout(requestID: UUID) {
        requestTimeoutTask?.cancel()
        requestTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.requestTimeoutNanoseconds
                )
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.fail(
                AppleOverlayTranslationError.requestTimedOut,
                requestID: requestID
            )
        }
    }

    private func finish(requestID: UUID) {
        guard let request = pendingRequest,
              request.id == requestID else {
            return
        }
        request.continuation.finish()
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
        pendingRequest = nil
        self.requestID = nil
    }

    private func finish(throwing error: Error, requestID: UUID) {
        guard let request = pendingRequest,
              request.id == requestID else {
            return
        }
        request.continuation.finish(throwing: error)
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
        pendingRequest = nil
        self.requestID = nil
    }

    private static func detectSourceLanguage(
        in segments: [OverlaySegment]
    ) -> Locale.Language? {
        let sample = segments
            .map(\.sourceText)
            .joined(separator: "\n")
        guard !sample.isEmpty else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(4_000)))
        guard let language = recognizer.dominantLanguage,
              language != .undetermined else {
            return nil
        }
        return Locale.Language(identifier: language.rawValue)
    }

    private static func localeLanguage(for identifier: String) -> Locale.Language {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")

        let resolvedIdentifier: String
        switch normalized {
        case "zh", "zh-cn", "zh-hans", "简体中文", "中文（简体）":
            resolvedIdentifier = "zh-Hans"
        case "zh-tw", "zh-hk", "zh-hant", "繁体中文", "繁體中文", "中文（繁体）", "中文（繁體）":
            resolvedIdentifier = "zh-Hant"
        case "en", "en-us", "en-gb", "英语", "英文":
            resolvedIdentifier = "en"
        case "ja", "ja-jp", "日语", "日文":
            resolvedIdentifier = "ja"
        case "ko", "ko-kr", "韩语", "韓語":
            resolvedIdentifier = "ko"
        default:
            resolvedIdentifier = normalized.isEmpty ? "zh-Hans" : normalized
        }
        return Locale.Language(identifier: resolvedIdentifier)
    }
}

@available(macOS 15.0, *)
struct AppleOverlayTranslationTaskModifier: ViewModifier {
    @ObservedObject var coordinator: AppleOverlayTranslationCoordinator
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onAppear {
                refreshConfiguration()
            }
            .onChange(of: coordinator.requestID) { _ in
                refreshConfiguration()
            }
            .translationTask(configuration) { @Sendable session in
                guard let request = await coordinator.currentWorkItem() else {
                    return
                }

                do {
                    let translatableSegments = request.segments.filter(\.shouldTranslate)
                    for segment in request.segments where !segment.shouldTranslate {
                        await coordinator.emit(
                            appleOverlayResultBuilder.localOriginalKeptResult(for: segment),
                            requestID: request.id
                        )
                    }
                    guard !translatableSegments.isEmpty else {
                        await coordinator.complete(requestID: request.id)
                        return
                    }

                    if let sourceLanguage = request.sourceLanguage {
                        let availability: LanguageAvailability
                        if #available(macOS 26.4, *) {
                            availability = LanguageAvailability(preferredStrategy: .lowLatency)
                        } else {
                            availability = LanguageAvailability()
                        }

                        switch await availability.status(
                            from: sourceLanguage,
                            to: request.targetLanguage
                        ) {
                        case .installed:
                            break
                        case .supported:
                            try await session.prepareTranslation()
                        case .unsupported:
                            throw AppleOverlayTranslationError.unsupportedLanguagePair
                        @unknown default:
                            throw AppleOverlayTranslationError.unsupportedLanguagePair
                        }
                    }

                    try Task.checkCancellation()
                    let segmentsByID = Dictionary(
                        uniqueKeysWithValues: translatableSegments.map { ($0.id, $0) }
                    )

                    let provider = AppleTranslationProvider(session: session)
                    let items = translatableSegments.map {
                        IdentifiedTranslationText(id: $0.id, text: $0.sourceText)
                    }
                    var returnedIDs = Set<String>()
                    for try await response in provider.translateBatchAsStream(items) {
                        try Task.checkCancellation()
                        guard let id = response.clientIdentifier,
                              let segment = segmentsByID[id],
                              returnedIDs.insert(id).inserted else {
                            continue
                        }
                        let translatedText = response.targetText
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !translatedText.isEmpty else {
                            continue
                        }
                        await coordinator.emit(
                            appleOverlayResultBuilder.localSuccessResult(
                                for: segment,
                                translatedText: translatedText
                            ),
                            requestID: request.id
                        )
                    }

                    guard returnedIDs.count == translatableSegments.count else {
                        throw TranslationProviderError.providerMessage(
                            "Apple 本地翻译没有返回完整结果。"
                        )
                    }
                    try Task.checkCancellation()
                    await coordinator.complete(requestID: request.id)
                } catch {
                    let reportedError: Error
                    if error is CancellationError {
                        reportedError = CancellationError()
                    } else if #available(macOS 26.0, *),
                              TranslationError.alreadyCancelled ~= error {
                        reportedError = CancellationError()
                    } else {
                        reportedError = error
                    }
                    await coordinator.fail(reportedError, requestID: request.id)
                }
            }
    }

    private func refreshConfiguration() {
        guard coordinator.requestID != nil,
              let pair = coordinator.languagePair else {
            configuration = nil
            return
        }

        if var current = configuration,
           current.source == pair.source,
           current.target == pair.target {
            current.invalidate()
            configuration = current
            return
        }

        if #available(macOS 26.4, *) {
            configuration = TranslationSession.Configuration(
                source: pair.source,
                target: pair.target,
                preferredStrategy: .lowLatency
            )
        } else {
            configuration = TranslationSession.Configuration(
                source: pair.source,
                target: pair.target
            )
        }
    }
}

enum AppleOverlayTranslationError: LocalizedError, Equatable {
    case unsupportedLanguagePair
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguagePair:
            "Apple 本地翻译暂不支持当前语言组合。"
        case .requestTimedOut:
            "Apple 本地翻译连续 12 秒没有返回结果。首次使用时语言包会继续在后台下载；请在“系统设置 → 通用 → 语言与地区 → 翻译语言”确认完成后，再点“继续翻译”。"
        }
    }
}
#endif
