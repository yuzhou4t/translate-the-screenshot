@testable import TTS
import Foundation

@_cdecl("runTTSPackageRegressionChecks")
public func runTTSPackageRegressionChecks() {
    announceRegressionCheck("MyMemory payload IDs")
    checkMyMemoryBatchPayloadsRespectUTF8LimitAndStableIDs()
    announceRegressionCheck("MyMemory UTF-8 limit")
    checkMyMemoryBatchPayloadsUseBytesAndLeaveOversizedOrReservedTextForFallback()
    announceRegressionCheck("MyMemory marker parser")
    checkMyMemoryBatchParserReturnsOnlyWellFormedPairs()
    announceRegressionCheck("native renderer button surface")
    checkScreenshotTranslationRendererPreservesButtonSurface()
    announceRegressionCheck("identified batch fallback")
    runAsyncScreenshotTranslationRegressionChecks()
    print("TTS screenshot translation regression checks passed")
}

private func runAsyncScreenshotTranslationRegressionChecks() {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        await checkIdentifiedBatchTranslationFallsBackOnlyForMissingSegmentsAndKeepsOrder()
        semaphore.signal()
    }
    precondition(
        semaphore.wait(timeout: .now() + 15) == .success,
        "async screenshot translation regression checks timed out"
    )
}

private func announceRegressionCheck(_ name: String) {
    FileHandle.standardError.write(Data("Running: \(name)\n".utf8))
}
