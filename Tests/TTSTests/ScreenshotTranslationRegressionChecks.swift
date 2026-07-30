@testable import TTS
import Foundation

@MainActor
func runTTSPackageRegressionChecks() async {
    announceRegressionCheck("Apple OCR layout")
    runAppleOCRLayoutEngineRegressionChecks()
    announceRegressionCheck("MyMemory payload IDs")
    checkMyMemoryBatchPayloadsRespectUTF8LimitAndStableIDs()
    announceRegressionCheck("MyMemory UTF-8 limit")
    checkMyMemoryBatchPayloadsUseBytesAndLeaveOversizedOrReservedTextForFallback()
    announceRegressionCheck("MyMemory marker parser")
    checkMyMemoryBatchParserReturnsOnlyWellFormedPairs()
    announceRegressionCheck("native renderer button surface")
    checkScreenshotTranslationRendererPreservesButtonSurface()
    announceRegressionCheck("identified batch fallback")
    await checkIdentifiedBatchTranslationFallsBackOnlyForMissingSegmentsAndKeepsOrder()
    announceRegressionCheck("bounded overlay translation cache")
    await checkImageOverlayTranslationCacheEvictsOldEntries()
    announceRegressionCheck("API retranslation preserves existing result")
    checkFailedHighQualityRetranslationPreservesExistingResult()
    announceRegressionCheck("coordinate translation hotkey routing")
    checkCoordinateTranslationHotkeyRoutesAndDefaults()
    announceRegressionCheck("screenshot overlay mode routing")
    checkScreenshotCaptureModesRouteOverlayTranslationEngines()
    announceRegressionCheck("screenshot overlay artifact retention")
    checkScreenshotOverlayRetentionRemovesOnlyExpiredOwnedArtifacts()
    announceRegressionCheck("screenshot annotation document and renderer")
    runScreenshotAnnotationRegressionChecks()
    announceRegressionCheck("legacy configuration compatibility")
    checkLegacyConfigurationDecodesAfterSimplification()
    announceRegressionCheck("fallback configuration invariants")
    checkFallbackConfigurationStaysValid()
    #if canImport(Translation)
    if #available(macOS 15.0, *) {
        announceRegressionCheck("Apple overlay repeated request lifecycle")
        checkRepeatedAppleOverlayRequestsInvalidateTranslationConfiguration()
    }
    #endif
    announceRegressionCheck("Volcengine image monthly policy")
    runVolcengineImageTranslationPolicyChecks()
    announceRegressionCheck("Volcengine image request and payload")
    await runVolcengineImageTranslationRegressionChecks()
    print("TTS screenshot translation regression checks passed")
}

private func announceRegressionCheck(_ name: String) {
    FileHandle.standardError.write(Data("Running: \(name)\n".utf8))
}
