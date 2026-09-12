#if canImport(Testing)
@testable import KeyboardShortcuts
@testable import TTS
import AppKit
import AVFoundation
import Foundation
import Testing

@Suite("Native screen recording")
struct ScreenRecordingTests {
    @Test("Default shortcut is Control Shift Z and Z can be recorded")
    @MainActor
    func defaultShortcut() throws {
        let shortcut = try #require(KeyboardShortcuts.Name.screenRecording.initial)

        #expect(shortcut == .init(.z, modifiers: [.control, .shift]))
        #expect(KeyboardShortcuts.Key.fromEventKeyCode(6) == .z)
        #expect(KeyboardShortcuts.Key.fromEventKeyCode(7) == nil)
    }

    @Test("State gates only valid recording controls")
    func stateControlGates() {
        #expect(ScreenRecordingState.recording(elapsed: 1).canPause)
        #expect(!ScreenRecordingState.paused(elapsed: 1).canPause)
        #expect(ScreenRecordingState.paused(elapsed: 1).canResume)
        #expect(!ScreenRecordingState.recording(elapsed: 1).canResume)
        #expect(ScreenRecordingState.recording(elapsed: 1).canStopOrCancelRecording)
        #expect(ScreenRecordingState.paused(elapsed: 1).canStopOrCancelRecording)
        #expect(!ScreenRecordingState.finalizing.canStopOrCancelRecording)
        #expect(ScreenRecordingState.selecting(.region).blocksOtherCapture)
        #expect(!ScreenRecordingState.failed("failure").blocksOtherCapture)
    }

    @Test("All audio option combinations preserve independent switches")
    func audioOptions() {
        let combinations = [
            ScreenRecordingOptions(capturesSystemAudio: false, capturesMicrophone: false),
            ScreenRecordingOptions(capturesSystemAudio: true, capturesMicrophone: false),
            ScreenRecordingOptions(capturesSystemAudio: false, capturesMicrophone: true),
            ScreenRecordingOptions(capturesSystemAudio: true, capturesMicrophone: true),
        ]

        #expect(combinations.map(\.isSilent) == [true, false, false, false])
        #expect(combinations.map(\.capturesAnyAudio) == [false, true, true, true])
        #expect(ScreenRecordingOptions.default == combinations[1])
        #expect(ScreenRecordingOptions.default.showsCursor)
    }

    @Test("Pause gaps are excluded from effective elapsed time")
    func effectiveElapsedTime() {
        #expect(ScreenRecordingController.effectiveElapsed(completed: 4.25, current: 1.5) == 5.75)
        #expect(ScreenRecordingController.effectiveElapsed(completed: 4.25, current: -8) == 4.25)
        #expect(ScreenRecordingController.effectiveElapsed(completed: 4.25, current: .nan) == 4.25)
        #expect(ScreenRecordingController.formatDuration(125.9) == "02:05")
    }

    @Test("Retina and multi-display coordinates map into ScreenCaptureKit space")
    func coordinateMapping() throws {
        let quartzWindow = CGRect(x: -1600, y: 100, width: 800, height: 300)
        #expect(
            ScreenRecordingGeometry.appKitRect(fromQuartzRect: quartzWindow, primaryScreenMaxY: 900)
                == CGRect(x: -1600, y: 500, width: 800, height: 300)
        )

        let display = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let region = CGRect(x: -1800, y: 100, width: 600, height: 400)
        let source = try #require(ScreenRecordingGeometry.sourceRect(for: region, in: display))
        #expect(source == CGRect(x: 120, y: 380, width: 600, height: 400))
        #expect(ScreenRecordingGeometry.evenPixelSize(for: CGSize(width: 301.5, height: 200.5), scale: 2)
            == CGSize(width: 604, height: 402))

        let crossDisplay = CGRect(x: -100, y: 0, width: 300, height: 300)
        #expect(
            ScreenRecordingGeometry.clampedRegion(
                crossDisplay,
                to: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            ) == CGRect(x: 0, y: 0, width: 200, height: 300)
        )
    }

    @Test("Output URLs keep MP4 extension and avoid collisions")
    func outputNaming() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-screen-name-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("TTS录屏-2026-09-08-12.30.00.mp4")
        try Data("occupied".utf8).write(to: existing)
        let next = ScreenRecordingController.uniqueURL(
            in: directory,
            stem: "TTS录屏-2026-09-08-12.30.00",
            pathExtension: "mp4"
        )

        #expect(next.lastPathComponent == "TTS录屏-2026-09-08-12.30.00-1.mp4")
    }

    @Test("Completed recordings use the Downloads root")
    func outputFolder() throws {
        let downloads = try #require(
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        )

        #expect(try ScreenRecordingController.outputFolderURL() == downloads)
    }

    @Test("Failure recovery moves every existing segment into an ordered folder")
    func failureRecovery() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-screen-recovery-\(UUID().uuidString)", isDirectory: true)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let recovery = base.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let first = source.appendingPathComponent("one.mp4")
        let missing = source.appendingPathComponent("missing.mp4")
        let third = source.appendingPathComponent("three.mp4")
        try Data("one".utf8).write(to: first)
        try Data("three".utf8).write(to: third)

        let recovered = try ScreenRecordingRecovery.preserve(
            segmentURLs: [first, missing, third],
            in: recovery
        )

        #expect(recovered.map(\.lastPathComponent) == [
            "可恢复片段-001.mp4",
            "可恢复片段-003.mp4",
        ])
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: third.path))
        #expect(try Data(contentsOf: recovered[0]) == Data("one".utf8))
        #expect(try Data(contentsOf: recovered[1]) == Data("three".utf8))
    }

    @Test("Existing users receive the recording quick action exactly once")
    @MainActor
    func quickActionMigration() throws {
        let suiteName = "TTSTests.ScreenRecordingMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var oldSettings = AIUsageSettings.default
        oldSettings.quickActionOrder.removeAll { $0 == .screenRecording }
        oldSettings.visibleQuickActionIDs.remove(.screenRecording)
        defaults.set(
            try JSONEncoder().encode(oldSettings),
            forKey: "tts.aiUsage.settings.v1"
        )

        let migrated = AIUsageSettingsStore(userDefaults: defaults)
        #expect(migrated.settings.quickActionOrder.first == .screenRecording)
        #expect(migrated.settings.visibleQuickActionIDs.contains(.screenRecording))

        migrated.setQuickActionVisible(false, id: .screenRecording)
        let reloaded = AIUsageSettingsStore(userDefaults: defaults)
        #expect(!reloaded.settings.visibleQuickActionIDs.contains(.screenRecording))
    }

    @Test("Two playable MP4 segments merge in chronological order", .timeLimit(.minutes(1)))
    func segmentMerge() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-screen-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.mp4")
        let second = directory.appendingPathComponent("second.mp4")
        let output = directory.appendingPathComponent("merged.mp4")
        let fixture = try #require(
            Bundle.module.url(
                forResource: "screen-recording-segment",
                withExtension: "mp4",
                subdirectory: "Fixtures"
            )
        )
        try FileManager.default.copyItem(at: fixture, to: first)
        try FileManager.default.copyItem(at: fixture, to: second)

        try await ScreenRecordingSegmentMerger.merge(
            segmentURLs: [first, second],
            outputURL: output
        )

        let asset = AVURLAsset(url: output)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(videoTracks.count == 1)
        #expect(duration >= 0.35)
        #expect(duration < 0.6)
    }
}
#endif
