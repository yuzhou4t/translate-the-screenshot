#if canImport(Testing)
@testable import TTS
import AppKit
import Testing

@Test("TTS package regression checks")
@MainActor
func packageRegressionChecks() async {
    _ = NSApplication.shared
    await runTTSPackageRegressionChecks()
}
#endif
