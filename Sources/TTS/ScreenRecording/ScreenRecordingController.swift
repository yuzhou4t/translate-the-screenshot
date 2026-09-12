@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import OSLog
@preconcurrency import ScreenCaptureKit

private struct ScreenRecordingSegment: Sendable {
    var url: URL
    var duration: TimeInterval
}

private final class ScreenRecordingFrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {}
}

private final class ScreenRecordingVideoWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "com.yuzhou4tc.tts.screen-recording.video-writer")

    private let outputURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var appendError: (any Error)?

    init(outputURL: URL, pixelSize: CGSize) throws {
        self.outputURL = outputURL
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        let averageBitRate = max(1_000_000, min(20_000_000, width * height * 4))
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: averageBitRate,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw ScreenRecordingError.couldNotStart("无法创建静音视频编码器")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ScreenRecordingError.couldNotStart(
                writer.error?.localizedDescription ?? "无法启动静音视频编码器"
            )
        }
        super.init()
    }

    var recordedDuration: TimeInterval {
        sampleQueue.sync {
            guard let firstPresentationTime, let lastPresentationTime else { return 0 }
            let duration = CMTimeGetSeconds(CMTimeSubtract(lastPresentationTime, firstPresentationTime))
            return duration.isFinite ? max(0, duration) : 0
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              isCompleteFrame(sampleBuffer),
              appendError == nil else {
            return
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid, presentationTime.isNumeric else { return }

        if firstPresentationTime == nil {
            firstPresentationTime = presentationTime
            writer.startSession(atSourceTime: presentationTime)
        }
        guard input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            lastPresentationTime = presentationTime
        } else {
            appendError = writer.error ?? ScreenRecordingError.couldNotFinish("静音视频写入失败")
        }
    }

    func finish() async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { continuation in
            sampleQueue.async { [self] in
                if let appendError {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: appendError)
                    return
                }
                guard let firstPresentationTime, let lastPresentationTime else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: ScreenRecordingError.noRecordedMedia)
                    return
                }
                let endTime = CMTimeAdd(
                    lastPresentationTime,
                    CMTime(value: 1, timescale: 30)
                )
                let duration = CMTimeGetSeconds(CMTimeSubtract(endTime, firstPresentationTime))
                input.markAsFinished()
                writer.endSession(atSourceTime: endTime)
                writer.finishWriting { [self] in
                    if writer.status == .completed, duration.isFinite, duration > 0 {
                        continuation.resume(returning: duration)
                    } else {
                        let error = writer.error
                            ?? ScreenRecordingError.couldNotFinish("无法完成静音视频写入")
                        try? FileManager.default.removeItem(at: outputURL)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func cancel() {
        sampleQueue.sync {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let statusRawValue = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: statusRawValue) else {
            return false
        }
        return status == .complete
    }
}

@MainActor
final class ScreenRecordingController: NSObject, ObservableObject {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.yuzhou4tc.tts",
        category: "ScreenRecording"
    )

    @Published private(set) var state: ScreenRecordingState = .idle {
        didSet { onStateChanged?() }
    }
    @Published private(set) var isTransitioning = false

    var onStateChanged: (() -> Void)?
    var onRequestControls: (() -> Void)?
    var canBeginSelection: (() -> Bool)?

    private let permissionManager: PermissionManager
    private let toastPanel: ToastPanel
    private let selectionController = ScreenRecordingSelectionController()
    private let countdownPanel = ScreenRecordingCountdownPanel()
    private let completionPanel = ScreenRecordingCompletionPanel()

    private var activeTarget: ScreenRecordingTarget?
    private var activeOptions: ScreenRecordingOptions = .default
    private var sessionDirectory: URL?
    private var segments: [ScreenRecordingSegment] = []
    private var stream: SCStream?
    private var frameSink: ScreenRecordingFrameSink?
    private let frameSinkQueue = DispatchQueue(label: "com.yuzhou4tc.tts.screen-recording.frames")
    private var videoWriter: ScreenRecordingVideoWriter?
    private var recordingOutput: SCRecordingOutput?
    private var currentSegmentURL: URL?
    private var finishContinuation: CheckedContinuation<Void, any Error>?
    private var finishTimeoutTask: Task<Void, Never>?
    private var pendingRecordingFailure: (any Error)?
    private var expectedStop = false
    private var accumulatedDuration: TimeInterval = 0
    private var timerTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    init(permissionManager: PermissionManager, toastPanel: ToastPanel) {
        self.permissionManager = permissionManager
        self.toastPanel = toastPanel
        super.init()
        selectionController.onTargetSelected = { [weak self] target, options in
            self?.beginCountdown(target: target, options: options)
        }
        selectionController.onCancelled = { [weak self] in
            self?.state = .idle
        }
        selectionController.onMicrophoneToggle = { [weak self] enabled in
            self?.handleMicrophoneToggle(enabled)
        }
        countdownPanel.onCancel = { [weak self] in
            self?.cancelSelectionOrCountdown()
        }
    }

    var isBlockingOtherCapture: Bool {
        state.blocksOtherCapture
    }

    var isRecordingSession: Bool {
        state.isRecordingSession
    }

    var isFinalizing: Bool {
        if case .finalizing = state { return true }
        return false
    }

    var formattedElapsed: String {
        Self.formatDuration(state.elapsed)
    }

    var statusTitle: String {
        switch state {
        case .recording:
            "正在录屏"
        case .paused:
            "录屏已暂停"
        case .finalizing:
            "正在保存录屏"
        case .selecting:
            "选择录屏范围"
        case let .countdown(remaining):
            "\(remaining) 秒后开始"
        case .completed:
            "录屏已保存"
        case let .failed(message):
            message
        case .idle:
            "录屏"
        }
    }

    func handleShortcut() {
        if state.isRecordingSession {
            onRequestControls?()
        } else if state.blocksOtherCapture {
            cancelSelectionOrCountdown()
        } else {
            startSelection()
        }
    }

    func startSelection() {
        guard !state.blocksOtherCapture else {
            if state.isRecordingSession { onRequestControls?() }
            return
        }
        guard canBeginSelection?() ?? true else {
            toastPanel.show("请先完成或取消当前截图任务")
            return
        }
        completionPanel.hide()
        guard permissionManager.isScreenRecordingTrusted else {
            permissionManager.requestScreenRecordingIfNeeded()
            permissionManager.openScreenRecordingSettings()
            toastPanel.show("请允许 TTS 屏幕与系统音频录制，授权后重新打开 TTS")
            return
        }

        state = .selecting(.region)
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                try Task.checkCancellation()
                guard case .selecting = self.state else { return }
                try self.selectionController.present(shareableContent: content)
            } catch is CancellationError {
                self.state = .idle
            } catch {
                self.fail(error)
            }
        }
    }

    func pause() {
        guard state.canPause, !isTransitioning else { return }
        isTransitioning = true
        timerTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.finishCurrentSegment()
                self.state = .paused(elapsed: self.accumulatedDuration)
            } catch {
                await self.salvageAfterFailure(error)
            }
            self.isTransitioning = false
        }
    }

    func resume() {
        guard state.canResume, !isTransitioning else { return }
        isTransitioning = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startNewSegment()
            } catch {
                self.state = .paused(elapsed: self.accumulatedDuration)
                self.toastPanel.show(error.localizedDescription)
            }
            self.isTransitioning = false
        }
    }

    func stopAndSave(interruptedMessage: String? = nil) {
        guard state.canStopOrCancelRecording, !isTransitioning else { return }
        isTransitioning = true
        state = .finalizing
        timerTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if self.stream != nil {
                    try await self.finishCurrentSegment()
                }
                let outputURL = try await self.finalizeRecording()
                self.state = .completed(outputURL)
                self.completionPanel.show(
                    fileURL: outputURL,
                    message: interruptedMessage ?? "录屏已保存"
                )
                self.resetSession(keepState: true)
            } catch {
                await self.salvageAfterFailure(error)
            }
            self.isTransitioning = false
        }
    }

    func cancelRecording() {
        guard state.canStopOrCancelRecording, !isTransitioning else { return }
        isTransitioning = true
        timerTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            if self.stream != nil {
                try? await self.finishCurrentSegment()
            }
            self.removeSessionDirectory()
            self.resetSession(keepState: false)
            self.state = .idle
            self.toastPanel.show("已取消录屏")
            self.isTransitioning = false
        }
    }

    func cancelSelectionOrCountdown() {
        switch state {
        case .selecting:
            selectionController.dismiss()
            operationTask?.cancel()
            state = .idle
        case .countdown:
            countdownTask?.cancel()
            countdownPanel.hide()
            state = .idle
        case .idle, .recording, .paused, .finalizing, .completed, .failed:
            break
        }
    }

    func prepareForTermination() async {
        if isFinalizing {
            await operationTask?.value
            return
        }
        if state.isRecordingSession {
            if stream != nil { try? await finishCurrentSegment() }
            _ = try? await finalizeRecording()
            resetSession(keepState: false)
        }
    }

    private func handleMicrophoneToggle(_ enabled: Bool) {
        guard enabled else { return }
        switch permissionManager.microphoneAuthorizationStatus {
        case .authorized:
            selectionController.updateMicrophoneOption(true)
        case .notDetermined:
            selectionController.updateMicrophoneOption(false)
            Task { [weak self] in
                guard let self else { return }
                let granted = await self.permissionManager.requestMicrophoneAccess()
                self.selectionController.updateMicrophoneOption(granted)
                if !granted {
                    self.toastPanel.show(ScreenRecordingError.microphonePermissionDenied.localizedDescription)
                    self.permissionManager.openMicrophoneSettings()
                }
            }
        case .denied, .restricted:
            selectionController.updateMicrophoneOption(false)
            toastPanel.show(ScreenRecordingError.microphonePermissionDenied.localizedDescription)
            permissionManager.openMicrophoneSettings()
        @unknown default:
            selectionController.updateMicrophoneOption(false)
        }
    }

    private func beginCountdown(target: ScreenRecordingTarget, options: ScreenRecordingOptions) {
        activeTarget = target
        activeOptions = options
        state = .countdown(3)
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let self else { return }
            for remaining in stride(from: 3, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                self.state = .countdown(remaining)
                self.countdownPanel.show(remaining, centeredIn: target.displayFrame)
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self.countdownPanel.hide()
            do {
                try self.prepareSessionDirectory()
                try await self.startNewSegment()
            } catch {
                self.fail(error)
                self.removeSessionDirectory()
            }
        }
    }

    private func startNewSegment() async throws {
        guard let target = activeTarget, let sessionDirectory else {
            throw ScreenRecordingError.targetUnavailable
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let (filter, pointSize) = try makeFilterAndPointSize(target: target, content: content)
        let scale = CGFloat(filter.pointPixelScale)
        let pixelSize = ScreenRecordingGeometry.evenPixelSize(for: pointSize, scale: scale)

        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = activeOptions.showsCursor
        configuration.capturesAudio = activeOptions.capturesSystemAudio
        configuration.captureMicrophone = activeOptions.capturesMicrophone
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.captureDynamicRange = .SDR
        if activeOptions.isSilent {
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
        }
        if case let .region(_, displayFrame, rect) = target {
            guard let sourceRect = ScreenRecordingGeometry.sourceRect(for: rect, in: displayFrame) else {
                throw ScreenRecordingError.invalidRegion
            }
            configuration.sourceRect = sourceRect
        }

        let segmentURL = sessionDirectory.appendingPathComponent(
            String(format: "segment-%03d.mp4", segments.count + 1)
        )
        let nextStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let nextVideoWriter: ScreenRecordingVideoWriter?
        let output: SCRecordingOutput?
        let nextFrameSink: ScreenRecordingFrameSink?
        if activeOptions.isSilent {
            nextVideoWriter = try ScreenRecordingVideoWriter(
                outputURL: segmentURL,
                pixelSize: pixelSize
            )
            output = nil
            nextFrameSink = nil
        } else {
            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = segmentURL
            outputConfiguration.videoCodecType = .h264
            outputConfiguration.outputFileType = .mp4
            output = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
            nextFrameSink = ScreenRecordingFrameSink()
            nextVideoWriter = nil
        }

        do {
            if let nextVideoWriter {
                try nextStream.addStreamOutput(
                    nextVideoWriter,
                    type: .screen,
                    sampleHandlerQueue: nextVideoWriter.sampleQueue
                )
            } else if let nextFrameSink, let output {
                try nextStream.addStreamOutput(
                    nextFrameSink,
                    type: .screen,
                    sampleHandlerQueue: frameSinkQueue
                )
                try nextStream.addRecordingOutput(output)
            }
            stream = nextStream
            frameSink = nextFrameSink
            videoWriter = nextVideoWriter
            recordingOutput = output
            currentSegmentURL = segmentURL
            expectedStop = false
            try await nextStream.startCapture()
        } catch {
            nextVideoWriter?.cancel()
            stream = nil
            frameSink = nil
            videoWriter = nil
            recordingOutput = nil
            currentSegmentURL = nil
            throw ScreenRecordingError.couldNotStart(error.localizedDescription)
        }

        state = .recording(elapsed: accumulatedDuration)
        startTimer()
    }

    private func makeFilterAndPointSize(
        target: ScreenRecordingTarget,
        content: SCShareableContent
    ) throws -> (SCContentFilter, CGSize) {
        switch target {
        case let .display(displayID, frame):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenRecordingError.targetUnavailable
            }
            let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            return (
                SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: []),
                frame.size
            )
        case let .window(windowID, frame, _):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenRecordingError.targetUnavailable
            }
            return (SCContentFilter(desktopIndependentWindow: window), frame.size)
        case let .region(displayID, displayFrame, rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }),
                  let clipped = ScreenRecordingGeometry.clampedRegion(rect, to: displayFrame) else {
                throw ScreenRecordingError.targetUnavailable
            }
            let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            return (
                SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: []),
                clipped.size
            )
        }
    }

    private func finishCurrentSegment() async throws {
        guard let activeStream = stream,
              let segmentURL = currentSegmentURL else {
            return
        }
        timerTask?.cancel()
        expectedStop = true
        let usesCustomVideoWriter = recordingOutput == nil && videoWriter != nil
        var finishError = pendingRecordingFailure
        var reportedDuration: TimeInterval = 0
        pendingRecordingFailure = nil
        if let output = recordingOutput {
            if finishError == nil {
                do {
                    try await withCheckedThrowingContinuation { continuation in
                        finishContinuation = continuation
                        finishTimeoutTask?.cancel()
                        finishTimeoutTask = Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(15))
                            guard !Task.isCancelled else { return }
                            self?.completeFinishContinuation(
                                error: ScreenRecordingError.couldNotFinish("完成文件录制超时")
                            )
                        }
                        do {
                            // Removing the recording output finalizes its file and delivers
                            // recordingOutputDidFinishRecording. Stop the stream only after
                            // the file writer has completed.
                            try activeStream.removeRecordingOutput(output)
                        } catch {
                            completeFinishContinuation(error: error)
                        }
                    }
                } catch {
                    finishError = error
                }
            } else {
                try? activeStream.removeRecordingOutput(output)
            }

            do {
                try await activeStream.stopCapture()
            } catch where finishError == nil {
                finishError = error
            }

            reportedDuration = CMTimeGetSeconds(output.recordedDuration)
            Self.logger.info(
                "Finished segment duration=\(reportedDuration, privacy: .public) size=\(output.recordedFileSize, privacy: .public)"
            )
        } else if let videoWriter {
            do {
                try await activeStream.stopCapture()
            } catch where finishError == nil {
                finishError = error
            }
            do {
                reportedDuration = try await videoWriter.finish()
                Self.logger.info(
                    "Finished silent segment duration=\(reportedDuration, privacy: .public)"
                )
            } catch where finishError == nil {
                finishError = error
            } catch {
                // Keep the original stream error when the writer also fails.
            }
        } else {
            try? await activeStream.stopCapture()
            finishError = finishError ?? ScreenRecordingError.noRecordedMedia
        }

        self.stream = nil
        frameSink = nil
        videoWriter = nil
        recordingOutput = nil
        currentSegmentURL = nil
        expectedStop = false

        do {
            try await appendSegmentIfUsable(
                segmentURL,
                reportedDuration: reportedDuration,
                trustsReportedDuration: usesCustomVideoWriter
            )
        } catch where finishError != nil {
            // Keep the original recorder error when a partial file is unusable.
        }
        if let finishError { throw finishError }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let current: TimeInterval
                if let output = self.recordingOutput {
                    current = CMTimeGetSeconds(output.recordedDuration)
                } else if let videoWriter = self.videoWriter {
                    current = videoWriter.recordedDuration
                } else {
                    return
                }
                let elapsed = Self.effectiveElapsed(
                    completed: self.accumulatedDuration,
                    current: current
                )
                self.state = .recording(elapsed: elapsed)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func prepareSessionDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTS-ScreenRecording", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionDirectory = directory
        segments = []
        accumulatedDuration = 0
    }

    private func finalizeRecording() async throws -> URL {
        guard !segments.isEmpty else { throw ScreenRecordingError.noRecordedMedia }
        let outputURL = try Self.uniqueOutputURL()
        if segments.count == 1, let segment = segments.first {
            try FileManager.default.moveItem(at: segment.url, to: outputURL)
        } else {
            try await ScreenRecordingSegmentMerger.merge(
                segmentURLs: segments.map(\.url),
                outputURL: outputURL
            )
        }
        removeSessionDirectory()
        return outputURL
    }

    private func salvageAfterFailure(_ error: any Error) async {
        timerTask?.cancel()
        if stream != nil {
            try? await finishCurrentSegment()
        }
        guard !segments.isEmpty else {
            removeSessionDirectory()
            fail(error)
            return
        }
        do {
            let recoveryFolder = try Self.uniqueRecoveryFolderURL()
            try FileManager.default.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
            _ = try ScreenRecordingRecovery.preserve(
                segmentURLs: segments.map(\.url),
                in: recoveryFolder
            )
            removeSessionDirectory()
            state = .failed("录屏中断；可用片段已保存到 \(recoveryFolder.lastPathComponent)")
            toastPanel.show("录屏中断，已保留可恢复片段")
        } catch {
            state = .failed(error.localizedDescription)
        }
        resetSession(keepState: true)
    }

    private func appendSegmentIfUsable(
        _ segmentURL: URL,
        reportedDuration: TimeInterval,
        trustsReportedDuration: Bool = false
    ) async throws {
        guard FileManager.default.fileExists(atPath: segmentURL.path),
              ((try? segmentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
            throw ScreenRecordingError.noRecordedMedia
        }
        let assetDuration: CMTime
        if trustsReportedDuration, reportedDuration.isFinite, reportedDuration > 0 {
            assetDuration = .zero
        } else {
            assetDuration = try await AVURLAsset(url: segmentURL).load(.duration)
        }
        let duration = max(
            reportedDuration.isFinite && reportedDuration > 0 ? reportedDuration : 0,
            CMTimeGetSeconds(assetDuration)
        )
        guard duration.isFinite, duration > 0 else {
            throw ScreenRecordingError.noRecordedMedia
        }
        segments.append(ScreenRecordingSegment(url: segmentURL, duration: duration))
        accumulatedDuration += duration
    }

    private func fail(_ error: any Error) {
        let message = error.localizedDescription
        state = .failed(message)
        toastPanel.show(message)
    }

    private func resetSession(keepState: Bool) {
        timerTask?.cancel()
        countdownTask?.cancel()
        countdownPanel.hide()
        selectionController.dismiss()
        stream = nil
        frameSink = nil
        videoWriter = nil
        recordingOutput = nil
        currentSegmentURL = nil
        finishContinuation = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        pendingRecordingFailure = nil
        expectedStop = false
        activeTarget = nil
        activeOptions = .default
        sessionDirectory = nil
        segments = []
        accumulatedDuration = 0
        if !keepState { state = .idle }
    }

    private func removeSessionDirectory() {
        guard let sessionDirectory else { return }
        try? FileManager.default.removeItem(at: sessionDirectory)
        self.sessionDirectory = nil
    }

    private func completeFinishContinuation(error: (any Error)?) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private static func uniqueOutputURL() throws -> URL {
        let folder = try outputFolderURL()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        let stem = "TTS录屏-\(formatter.string(from: Date()))"
        return uniqueURL(in: folder, stem: stem, pathExtension: "mp4")
    }

    private static func uniqueRecoveryFolderURL() throws -> URL {
        let folder = try outputFolderURL()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        return uniqueURL(
            in: folder,
            stem: "恢复-TTS录屏-\(formatter.string(from: Date()))",
            pathExtension: nil
        )
    }

    nonisolated static func outputFolderURL() throws -> URL {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw ScreenRecordingError.couldNotCreateOutputFolder
        }
        do {
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        } catch {
            throw ScreenRecordingError.couldNotCreateOutputFolder
        }
        return downloads
    }

    nonisolated static func uniqueURL(in folder: URL, stem: String, pathExtension: String?) -> URL {
        for suffix in 0...9_999 {
            let name = suffix == 0 ? stem : "\(stem)-\(suffix)"
            var candidate = folder.appendingPathComponent(name, isDirectory: pathExtension == nil)
            if let pathExtension { candidate.appendPathExtension(pathExtension) }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        var fallback = folder.appendingPathComponent("\(stem)-\(UUID().uuidString)")
        if let pathExtension { fallback.appendPathExtension(pathExtension) }
        return fallback
    }

    nonisolated static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    nonisolated static func effectiveElapsed(completed: TimeInterval, current: TimeInterval) -> TimeInterval {
        max(0, completed) + (current.isFinite ? max(0, current) : 0)
    }
}

extension ScreenRecordingController: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Self.logger.info("Recording output started")
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Self.logger.info(
            "Recording output finalized duration=\(CMTimeGetSeconds(recordingOutput.recordedDuration), privacy: .public) size=\(recordingOutput.recordedFileSize, privacy: .public)"
        )
        Task { @MainActor [weak self] in
            guard self?.recordingOutput === recordingOutput else { return }
            self?.completeFinishContinuation(error: nil)
        }
    }

    nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: any Error
    ) {
        Self.logger.error("Recording output failed: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor [weak self] in
            guard self?.recordingOutput === recordingOutput else { return }
            if self?.finishContinuation != nil {
                self?.completeFinishContinuation(error: error)
            } else {
                self?.pendingRecordingFailure = error
                self?.stopAndSave(interruptedMessage: "录屏中断，已保存可用内容")
            }
        }
    }
}

extension ScreenRecordingController: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Self.logger.error("Capture stream stopped unexpectedly: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream, !self.expectedStop else { return }
            self.stopAndSave(interruptedMessage: "录屏中断，已保存可用内容")
        }
    }
}

enum ScreenRecordingSegmentMerger {
    static func merge(segmentURLs: [URL], outputURL: URL) async throws {
        let composition = AVMutableComposition()
        var insertTime = CMTime.zero
        for url in segmentURLs {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            try await composition.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: asset,
                at: insertTime
            )
            insertTime = CMTimeAdd(insertTime, duration)
        }
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw ScreenRecordingError.couldNotFinish("无法创建视频合并器")
        }
        do {
            try await exporter.export(to: outputURL, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}

enum ScreenRecordingRecovery {
    static func preserve(segmentURLs: [URL], in recoveryFolder: URL) throws -> [URL] {
        var recovered: [URL] = []
        for (index, segmentURL) in segmentURLs.enumerated() {
            guard FileManager.default.fileExists(atPath: segmentURL.path) else { continue }
            let target = recoveryFolder.appendingPathComponent(
                String(format: "可恢复片段-%03d.mp4", index + 1)
            )
            try FileManager.default.moveItem(at: segmentURL, to: target)
            recovered.append(target)
        }
        return recovered
    }
}
