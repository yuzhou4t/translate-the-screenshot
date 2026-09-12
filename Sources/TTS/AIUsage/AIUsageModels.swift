import Foundation

enum AIUsageProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case grok
    case deepSeek = "deepseek"
    case miniMax = "minimax"
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            "ChatGPT / Codex"
        case .grok:
            "Grok 共享额度"
        case .deepSeek:
            "DeepSeek"
        case .miniMax:
            "MiniMax Coding Plan"
        case .gemini:
            "AntiGravity"
        }
    }

    var systemImage: String {
        switch self {
        case .codex:
            "sparkles"
        case .grok:
            "bolt.fill"
        case .deepSeek:
            "wave.3.right"
        case .miniMax:
            "circle.grid.2x2.fill"
        case .gemini:
            "arrow.up.right.circle.fill"
        }
    }
}

enum MenuQuickActionID: String, Codable, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case screenshotClipboard
    case translateSelection
    case inputTranslate
    case screenshotTranslate
    case localOverlayTranslate
    case apiOverlayTranslate
    case volcengineImageTranslate
    case screenshotOCR
    case silentScreenshotOCR
    case imageFileOCR

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .screenRecording:
            "录屏"
        case .screenshotClipboard:
            "截图到剪贴板"
        case .translateSelection:
            "翻译选中文字"
        case .inputTranslate:
            "输入翻译"
        case .screenshotTranslate:
            "截图翻译"
        case .localOverlayTranslate:
            "Apple 本地坐标翻译"
        case .apiOverlayTranslate:
            "API 高质量坐标翻译"
        case .volcengineImageTranslate:
            "火山图片翻译 Beta"
        case .screenshotOCR:
            "截图 OCR"
        case .silentScreenshotOCR:
            "静默截图 OCR"
        case .imageFileOCR:
            "图片文件 OCR"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .screenRecording:
            "录屏"
        case .screenshotClipboard:
            "截图到剪贴板"
        case .translateSelection:
            "划词翻译"
        case .inputTranslate:
            "输入翻译"
        case .screenshotTranslate:
            "截图翻译"
        case .localOverlayTranslate:
            "Apple 坐标翻译"
        case .apiOverlayTranslate:
            "API 坐标翻译"
        case .volcengineImageTranslate:
            "火山图片翻译"
        case .screenshotOCR:
            "截图 OCR"
        case .silentScreenshotOCR:
            "静默 OCR"
        case .imageFileOCR:
            "图片 OCR"
        }
    }

    var systemImage: String {
        switch self {
        case .screenRecording:
            "record.circle"
        case .screenshotClipboard:
            "camera.viewfinder"
        case .translateSelection:
            "text.cursor"
        case .inputTranslate:
            "square.and.pencil"
        case .screenshotTranslate:
            "viewfinder"
        case .localOverlayTranslate:
            "apple.logo"
        case .apiOverlayTranslate:
            "sparkles"
        case .volcengineImageTranslate:
            "photo"
        case .screenshotOCR:
            "text.viewfinder"
        case .silentScreenshotOCR:
            "doc.on.clipboard"
        case .imageFileOCR:
            "photo.on.rectangle"
        }
    }
}

enum MiniMaxUsageRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case chinaMainland
    case global

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chinaMainland:
            "中国大陆"
        case .global:
            "国际"
        }
    }

    var apiBaseURL: URL {
        switch self {
        case .chinaMainland:
            URL(string: "https://api.minimaxi.com")!
        case .global:
            URL(string: "https://api.minimax.io")!
        }
    }
}

enum AIUsageMetric: Codable, Equatable, Sendable {
    case quotaWindow(
        label: String,
        remainingFraction: Double,
        resetsAt: Date?
    )
    case balance(
        label: String,
        total: Double,
        currency: String,
        paid: Double?,
        granted: Double?
    )
    case amount(
        label: String,
        remaining: Double?,
        limit: Double?,
        unit: String,
        resetsAt: Date?,
        isUnlimited: Bool,
        warnsWhenLow: Bool
    )

    var label: String {
        switch self {
        case .quotaWindow(let label, _, _),
             .balance(let label, _, _, _, _),
             .amount(let label, _, _, _, _, _, _):
            label
        }
    }

    var remainingFraction: Double? {
        switch self {
        case .quotaWindow(_, let remainingFraction, _):
            return Self.clamp(remainingFraction)
        case .amount(_, let remaining, let limit, _, _, let isUnlimited, _):
            guard !isUnlimited, let remaining, let limit, limit > 0 else {
                return nil
            }
            return Self.clamp(remaining / limit)
        case .balance:
            return nil
        }
    }

    var needsAttention: Bool {
        switch self {
        case .quotaWindow(_, let remainingFraction, _):
            return Self.clamp(remainingFraction) <= 0.20
        case .balance(_, let total, _, _, _):
            return total <= 0
        case .amount(_, let remaining, let limit, _, _, let isUnlimited, let warnsWhenLow):
            guard !isUnlimited, warnsWhenLow else { return false }
            if let remaining, let limit, limit > 0 {
                return remaining / limit <= 0.20
            }
            return remaining == 0
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

struct AIUsageSnapshot: Codable, Equatable, Identifiable, Sendable {
    var providerID: AIUsageProviderID
    var metrics: [AIUsageMetric]
    var planName: String?
    var source: String
    var updatedAt: Date
    var usageBreakdown: [AIUsageBreakdownItem]? = nil

    var id: AIUsageProviderID { providerID }
    var needsAttention: Bool { metrics.contains(where: \.needsAttention) }
}

struct AIUsageBreakdownItem: Codable, Equatable, Identifiable, Sendable {
    var label: String
    var usedFraction: Double

    var id: String { label }
}

enum AIUsageFailureCategory: String, Codable, Sendable {
    case notConfigured
    case authentication
    case unavailable
    case network
    case malformedResponse
    case timeout
}

struct AIUsageFailure: Error, Codable, Equatable, Sendable {
    var category: AIUsageFailureCategory
    var message: String

    static func notConfigured(_ message: String) -> Self {
        .init(category: .notConfigured, message: message)
    }

    static func authentication(_ message: String) -> Self {
        .init(category: .authentication, message: message)
    }

    static func unavailable(_ message: String) -> Self {
        .init(category: .unavailable, message: message)
    }

    static func network(_ message: String = "暂时无法连接服务商。") -> Self {
        .init(category: .network, message: message)
    }

    static func malformed(_ message: String = "服务商返回了无法识别的数据。") -> Self {
        .init(category: .malformedResponse, message: message)
    }

    static func timeout(_ message: String = "读取额度超时，请稍后重试。") -> Self {
        .init(category: .timeout, message: message)
    }
}

struct AIUsageProviderViewState: Equatable, Sendable {
    var snapshot: AIUsageSnapshot?
    var failure: AIUsageFailure?
    var isRefreshing: Bool
    var lastAttemptAt: Date?

    static let empty = AIUsageProviderViewState(
        snapshot: nil,
        failure: nil,
        isRefreshing: false,
        lastAttemptAt: nil
    )

    func isStale(now: Date = .now, staleAfter: TimeInterval = 15 * 60) -> Bool {
        guard let snapshot else { return false }
        return failure != nil || now.timeIntervalSince(snapshot.updatedAt) > staleAfter
    }
}

struct AIUsageProviderDescriptor: Identifiable, Sendable {
    var id: AIUsageProviderID
    var setupSummary: String
}

protocol AIUsageProvider: Sendable {
    var id: AIUsageProviderID { get }
    func fetchUsage() async throws -> AIUsageSnapshot
}

protocol AIUsageHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionAIUsageHTTPClient: AIUsageHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AIUsageFailure.network()
        }
        return (data, response)
    }
}
