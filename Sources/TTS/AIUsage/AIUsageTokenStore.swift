import Foundation

enum AIUsageTokenPeriod: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .day: "今日"
        case .week: "本周"
        case .month: "本月"
        }
    }

    func startDate(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .day:
            return calendar.startOfDay(for: now)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.startOfDay(for: now)
        case .month:
            return calendar.dateInterval(of: .month, for: now)?.start
                ?? calendar.startOfDay(for: now)
        }
    }
}

struct AIUsageTokenSummary: Equatable, Sendable {
    var providerID: AIUsageProviderID
    var period: AIUsageTokenPeriod
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int
    var source: String
    var updatedAt: Date

    var totalTokens: Int { inputTokens + outputTokens }

    var cacheHitFraction: Double? {
        guard inputTokens > 0 else { return nil }
        return min(max(Double(cachedInputTokens) / Double(inputTokens), 0), 1)
    }
}

struct AIUsageTokenViewState: Equatable, Sendable {
    var summary: AIUsageTokenSummary?
    var isLoading: Bool
    var message: String?
}

enum AIUsageTokenReadError: Error, Equatable, Sendable {
    case unsupported
    case noData

    var message: String {
        switch self {
        case .unsupported:
            "此服务暂时没有可靠的本地 Token 记录。"
        case .noData:
            "所选时间内还没有可统计的 Token 记录。"
        }
    }
}

protocol AIUsageLocalTokenReading: Sendable {
    func read(
        providerID: AIUsageProviderID,
        period: AIUsageTokenPeriod,
        now: Date
    ) async throws -> AIUsageTokenSummary
}

@MainActor
final class AIUsageTokenStore: ObservableObject {
    @Published private var summaries: [String: AIUsageTokenSummary] = [:]
    @Published private var loadingKeys: Set<String> = []
    @Published private var messages: [String: String] = [:]

    private let reader: any AIUsageLocalTokenReading

    init(reader: any AIUsageLocalTokenReading = AIUsageLocalTokenReader()) {
        self.reader = reader
    }

    func state(
        providerID: AIUsageProviderID,
        period: AIUsageTokenPeriod
    ) -> AIUsageTokenViewState {
        let key = Self.key(providerID: providerID, period: period)
        return AIUsageTokenViewState(
            summary: summaries[key],
            isLoading: loadingKeys.contains(key),
            message: messages[key]
        )
    }

    func load(providerID: AIUsageProviderID, period: AIUsageTokenPeriod) {
        let key = Self.key(providerID: providerID, period: period)
        guard !loadingKeys.contains(key) else { return }
        loadingKeys.insert(key)
        messages[key] = nil

        Task { [reader] in
            do {
                let summary = try await reader.read(
                    providerID: providerID,
                    period: period,
                    now: .now
                )
                summaries[key] = summary
            } catch let error as AIUsageTokenReadError {
                messages[key] = error.message
            } catch {
                messages[key] = "暂时无法读取本地 Token 记录。"
            }
            loadingKeys.remove(key)
        }
    }

    private static func key(
        providerID: AIUsageProviderID,
        period: AIUsageTokenPeriod
    ) -> String {
        "\(providerID.rawValue).\(period.rawValue)"
    }
}

struct AIUsageLocalTokenReader: AIUsageLocalTokenReading {
    private let environment: [String: String]
    private let homeDirectory: String

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func read(
        providerID: AIUsageProviderID,
        period: AIUsageTokenPeriod,
        now: Date
    ) async throws -> AIUsageTokenSummary {
        try await Task.detached(priority: .utility) {
            switch providerID {
            case .codex:
                return try readCodex(period: period, now: now)
            case .grok:
                return try readGrok(period: period, now: now)
            case .deepSeek, .miniMax, .gemini:
                throw AIUsageTokenReadError.unsupported
            }
        }.value
    }

    private func readCodex(
        period: AIUsageTokenPeriod,
        now: Date
    ) throws -> AIUsageTokenSummary {
        let root = environment["CODEX_HOME"]
            ?? URL(fileURLWithPath: homeDirectory).appendingPathComponent(".codex").path
        let sessionsRoot = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let urls = Self.codexSessionFiles(
            sessionsRoot: sessionsRoot,
            since: period.startDate(now: now),
            now: now
        )
        var totals = AIUsageTokenCounts.zero
        for url in urls {
            guard let data = Self.tailData(url: url, maximumBytes: 128 * 1024),
                  let counts = Self.parseCodexSessionTail(data) else { continue }
            totals += counts
        }
        guard totals.totalTokens > 0 else { throw AIUsageTokenReadError.noData }
        return AIUsageTokenSummary(
            providerID: .codex,
            period: period,
            inputTokens: totals.input,
            cachedInputTokens: totals.cachedInput,
            outputTokens: totals.output,
            reasoningTokens: totals.reasoning,
            source: "Codex 本地会话",
            updatedAt: now
        )
    }

    private func readGrok(
        period: AIUsageTokenPeriod,
        now: Date
    ) throws -> AIUsageTokenSummary {
        let root = environment["GROK_HOME"]
            ?? URL(fileURLWithPath: homeDirectory).appendingPathComponent(".grok").path
        let url = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("logs/unified.jsonl")
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw AIUsageTokenReadError.noData
        }
        let totals = Self.parseGrokUnifiedLog(
            data,
            since: period.startDate(now: now)
        )
        guard totals.totalTokens > 0 else { throw AIUsageTokenReadError.noData }
        return AIUsageTokenSummary(
            providerID: .grok,
            period: period,
            inputTokens: totals.input,
            cachedInputTokens: totals.cachedInput,
            outputTokens: totals.output,
            reasoningTokens: totals.reasoning,
            source: "Grok 本地统一日志",
            updatedAt: now
        )
    }

    static func parseCodexSessionTail(_ data: Data) -> AIUsageTokenCounts? {
        for line in data.split(separator: 0x0A).reversed() {
            guard line.range(of: Data("\"token_count\"".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { continue }
            return AIUsageTokenCounts(
                input: integer(total["input_tokens"]),
                cachedInput: integer(total["cached_input_tokens"]),
                output: integer(total["output_tokens"]),
                reasoning: integer(total["reasoning_output_tokens"])
            )
        }
        return nil
    }

    static func parseGrokUnifiedLog(_ data: Data, since: Date) -> AIUsageTokenCounts {
        var totals = AIUsageTokenCounts.zero
        for line in data.split(separator: 0x0A) {
            guard line.range(of: Data("shell.turn.inference_done".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["msg"] as? String == "shell.turn.inference_done",
                  let timestamp = object["ts"] as? String,
                  let date = parseDate(timestamp),
                  date >= since,
                  let context = object["ctx"] as? [String: Any] else { continue }
            totals += AIUsageTokenCounts(
                input: integer(context["prompt_tokens"]),
                cachedInput: integer(context["cached_prompt_tokens"]),
                output: integer(context["completion_tokens"]),
                reasoning: integer(context["reasoning_tokens"])
            )
        }
        return totals
    }

    private static func codexSessionFiles(
        sessionsRoot: URL,
        since: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> [URL] {
        var urls: [URL] = []
        var day = calendar.startOfDay(for: since)
        let finalDay = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")

        while day <= finalDay {
            formatter.dateFormat = "yyyy"
            let year = formatter.string(from: day)
            formatter.dateFormat = "MM"
            let month = formatter.string(from: day)
            formatter.dateFormat = "dd"
            let date = formatter.string(from: day)
            let directory = sessionsRoot
                .appendingPathComponent(year, isDirectory: true)
                .appendingPathComponent(month, isDirectory: true)
                .appendingPathComponent(date, isDirectory: true)
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                urls.append(contentsOf: contents.filter { $0.pathExtension == "jsonl" })
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return urls
    }

    private static func tailData(url: URL, maximumBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct AIUsageTokenCounts: Equatable, Sendable {
    var input: Int
    var cachedInput: Int
    var output: Int
    var reasoning: Int

    static let zero = AIUsageTokenCounts(input: 0, cachedInput: 0, output: 0, reasoning: 0)
    var totalTokens: Int { input + output }

    static func += (lhs: inout AIUsageTokenCounts, rhs: AIUsageTokenCounts) {
        lhs.input += rhs.input
        lhs.cachedInput += rhs.cachedInput
        lhs.output += rhs.output
        lhs.reasoning += rhs.reasoning
    }
}
