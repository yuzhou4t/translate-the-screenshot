import CoreGraphics
import Foundation

enum ScreenRecordingMode: String, CaseIterable, Identifiable, Sendable {
    case display
    case window
    case region

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .display:
            "整块屏幕"
        case .window:
            "单个窗口"
        case .region:
            "自定义区域"
        }
    }

    var systemImage: String {
        switch self {
        case .display:
            "display"
        case .window:
            "macwindow"
        case .region:
            "viewfinder"
        }
    }
}

struct ScreenRecordingOptions: Equatable, Sendable {
    var capturesSystemAudio = true
    var capturesMicrophone = false
    var showsCursor = true

    static let `default` = ScreenRecordingOptions()

    var isSilent: Bool {
        !capturesSystemAudio && !capturesMicrophone
    }

    var capturesAnyAudio: Bool {
        capturesSystemAudio || capturesMicrophone
    }
}

enum ScreenRecordingTarget: Equatable, Sendable {
    case display(id: CGDirectDisplayID, frame: CGRect)
    case window(id: CGWindowID, frame: CGRect, title: String)
    case region(displayID: CGDirectDisplayID, displayFrame: CGRect, rect: CGRect)

    var mode: ScreenRecordingMode {
        switch self {
        case .display:
            .display
        case .window:
            .window
        case .region:
            .region
        }
    }

    var displayFrame: CGRect {
        switch self {
        case let .display(_, frame):
            frame
        case let .window(_, frame, _):
            frame
        case let .region(_, _, rect):
            rect
        }
    }

    var description: String {
        switch self {
        case .display:
            "整块屏幕"
        case let .window(_, _, title):
            title.isEmpty ? "单个窗口" : title
        case .region:
            "自定义区域"
        }
    }
}

enum ScreenRecordingState: Equatable, Sendable {
    case idle
    case selecting(ScreenRecordingMode)
    case countdown(Int)
    case recording(elapsed: TimeInterval)
    case paused(elapsed: TimeInterval)
    case finalizing
    case completed(URL)
    case failed(String)

    var blocksOtherCapture: Bool {
        switch self {
        case .idle, .completed, .failed:
            false
        case .selecting, .countdown, .recording, .paused, .finalizing:
            true
        }
    }

    var isRecordingSession: Bool {
        switch self {
        case .recording, .paused, .finalizing:
            true
        case .idle, .selecting, .countdown, .completed, .failed:
            false
        }
    }

    var canPause: Bool {
        if case .recording = self { return true }
        return false
    }

    var canResume: Bool {
        if case .paused = self { return true }
        return false
    }

    var canStopOrCancelRecording: Bool {
        switch self {
        case .recording, .paused:
            true
        case .idle, .selecting, .countdown, .finalizing, .completed, .failed:
            false
        }
    }

    var elapsed: TimeInterval {
        switch self {
        case let .recording(elapsed), let .paused(elapsed):
            elapsed
        case .idle, .selecting, .countdown, .finalizing, .completed, .failed:
            0
        }
    }
}

enum ScreenRecordingError: LocalizedError, Equatable, Sendable {
    case permissionRequired
    case microphonePermissionDenied
    case noShareableContent
    case targetUnavailable
    case invalidRegion
    case couldNotStart(String)
    case couldNotFinish(String)
    case noRecordedMedia
    case couldNotCreateOutputFolder

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            "请允许 TTS 进行屏幕与系统音频录制，然后重新打开 TTS。"
        case .microphonePermissionDenied:
            "没有麦克风权限；已关闭麦克风录制。"
        case .noShareableContent:
            "没有找到可录制的屏幕或窗口。"
        case .targetUnavailable:
            "所选屏幕或窗口已经不可用，请重新选择。"
        case .invalidRegion:
            "录制区域太小，请重新框选。"
        case let .couldNotStart(message):
            "无法开始录屏：\(message)"
        case let .couldNotFinish(message):
            "无法完成录屏：\(message)"
        case .noRecordedMedia:
            "本次录屏没有生成可用内容。"
        case .couldNotCreateOutputFolder:
            "无法访问“下载”文件夹。"
        }
    }
}
