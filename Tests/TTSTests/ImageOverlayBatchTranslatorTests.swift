@testable import TTS
import Foundation

func checkIdentifiedBatchTranslationFallsBackOnlyForMissingSegmentsAndKeepsOrder() async {
    let recorder = SingleTranslationRecorder()
    let provider = PartialIdentifiedBatchProvider(recorder: recorder)
    let translator = ImageOverlayBatchTranslator(cache: ImageOverlayTranslationCache())
    let segments = [
        testSegment(id: "first", text: "First"),
        testSegment(id: "second", text: "Second")
    ]

    let results = await translator.translate(
        segments: segments,
        targetLanguage: "简体中文",
        provider: provider,
        modelName: ""
    )

    precondition(results.map(\.segmentID) == ["first", "second"])
    precondition(results.map(\.translatedText) == ["batch:First", "single:Second"])
    precondition(results.allSatisfy { $0.status == .success })
    let individuallyTranslatedTexts = await recorder.texts
    precondition(individuallyTranslatedTexts == ["Second"])
}

func checkImageOverlayTranslationCacheEvictsOldEntries() async {
    let cache = ImageOverlayTranslationCache(
        maximumEntryCount: 2,
        retentionInterval: 60
    )
    let keys = ["first", "second", "third"].map {
        ImageOverlayTranslationCache.Key(
            sourceText: $0,
            targetLanguage: "简体中文",
            providerID: "test",
            modelName: "test",
            translationMode: .imageOverlay
        )
    }

    for key in keys {
        await cache.insert(
            translatedText: "translated-\(key.sourceText)",
            lineTranslations: [],
            for: key
        )
    }

    let retained = await cache.values(for: keys)
    precondition(retained.count == 2)
    precondition(retained[keys[2]]?.translatedText == "translated-third")
}

func checkFailedHighQualityRetranslationPreservesExistingResult() {
    let segment = testSegment(id: "preserve-existing", text: "Original")
    let existingResult = ImageOverlayTranslationResult(
        segmentID: segment.id,
        sourceText: segment.sourceText,
        translatedText: "已有译文",
        lineTranslations: [],
        status: .success,
        errorMessage: nil
    )
    var state = ImageOverlaySegmentState(
        segment: segment,
        phase: .translated,
        translationResult: existingResult,
        errorMessage: nil,
        isExcluded: false
    )

    state.applyTranslationResult(
        ImageOverlayTranslationResult(
            segmentID: segment.id,
            sourceText: segment.sourceText,
            translatedText: segment.sourceText,
            lineTranslations: [],
            status: .originalKept,
            errorMessage: "API unavailable"
        )
    )

    precondition(state.translationResult == existingResult)
    precondition(state.phase == .translated)
    precondition(state.errorMessage == "API unavailable")
}

private actor SingleTranslationRecorder {
    private(set) var texts: [String] = []

    func append(_ text: String) {
        texts.append(text)
    }
}

private struct PartialIdentifiedBatchProvider: IdentifiedBatchTranslationProvider {
    let id: TranslationProviderID = .myMemory
    let displayName = "Partial batch test provider"
    let recorder: SingleTranslationRecorder

    func translateBatch(
        _ items: [IdentifiedTranslationText],
        sourceLanguage: String?,
        targetLanguage: String
    ) async throws -> [IdentifiedTranslationTextResult] {
        guard let first = items.first else {
            return []
        }
        return [
            IdentifiedTranslationTextResult(
                id: first.id,
                translatedText: "batch:\(first.text)"
            )
        ]
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        await recorder.append(request.text)
        return TranslationResponse(
            translatedText: "single:\(request.text)",
            providerID: id,
            detectedSourceLanguage: nil
        )
    }
}

private func testSegment(
    id: String,
    text: String
) -> OverlaySegment {
    let box = CGRect(x: 20, y: 20, width: 160, height: 36)
    return OverlaySegment(
        id: id,
        sourceBlockIDs: [],
        sourceAtomIDs: [],
        sourceText: text,
        lines: [],
        boundingBox: box,
        lineBoxes: [box],
        eraseBoxes: [box],
        role: .paragraph,
        readingOrder: 0,
        shouldTranslate: true
    )
}
