#if canImport(Translation)
@testable import TTS
import CoreGraphics
import Translation

@available(macOS 15.0, *)
@MainActor
func checkRepeatedAppleOverlayRequestsInvalidateTranslationConfiguration() {
    let coordinator = AppleOverlayTranslationCoordinator()
    let segment = OverlaySegment(
        id: "second-request-regression",
        sourceBlockIDs: [],
        sourceAtomIDs: [],
        sourceText: "This sentence is long enough for reliable English language detection.",
        lines: [],
        boundingBox: CGRect(x: 0, y: 0, width: 320, height: 48),
        lineBoxes: [CGRect(x: 0, y: 0, width: 320, height: 48)],
        eraseBoxes: [CGRect(x: 0, y: 0, width: 320, height: 48)],
        role: .paragraph,
        readingOrder: 0,
        shouldTranslate: true
    )

    let firstStream = coordinator.translate(
        segments: [segment],
        targetLanguage: "简体中文"
    )
    guard let firstRequestID = coordinator.requestID,
          let firstConfiguration = coordinator.configuration else {
        preconditionFailure("first Apple overlay request must create a configuration")
    }
    coordinator.complete(requestID: firstRequestID)

    precondition(coordinator.requestID == nil)
    precondition(coordinator.configuration?.version == firstConfiguration.version)

    let secondStream = coordinator.translate(
        segments: [segment],
        targetLanguage: "简体中文"
    )
    guard let secondConfiguration = coordinator.configuration else {
        preconditionFailure("second Apple overlay request must retain a configuration")
    }

    precondition(secondConfiguration.source == firstConfiguration.source)
    precondition(secondConfiguration.target == firstConfiguration.target)
    precondition(secondConfiguration.version != firstConfiguration.version)

    coordinator.cancel()
    _ = (firstStream, secondStream)
}
#endif
