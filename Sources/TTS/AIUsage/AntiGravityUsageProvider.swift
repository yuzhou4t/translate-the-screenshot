import Darwin
import Foundation

struct AntiGravityUsageProvider: AIUsageProvider {
    let id: AIUsageProviderID = .gemini

    func fetchUsage() async throws -> AIUsageSnapshot {
        let processOutput: String
        do {
            processOutput = try await AIUsageCommandRunner.run(
                executable: "/bin/ps",
                arguments: ["-ax", "-o", "pid=,command="],
                timeout: 4
            )
        } catch let error as AIUsageCommandError {
            switch error {
            case .timeout:
                throw AIUsageFailure.timeout()
            case .startFailed:
                throw AIUsageFailure.unavailable("无法启动 AntiGravity 本地服务检查。")
            case .failed:
                throw AIUsageFailure.unavailable("AntiGravity 本地服务检查未正常完成。")
            case .outputTooLarge:
                throw AIUsageFailure.unavailable("本机进程列表过大，暂时无法定位 AntiGravity。")
            }
        } catch {
            throw AIUsageFailure.unavailable("暂时无法检查 AntiGravity 本地服务。")
        }

        let processes = Self.processes(from: processOutput)
        guard !processes.isEmpty else {
            throw AIUsageFailure.unavailable("AntiGravity 未运行；请打开并保持登录后刷新。")
        }

        var lastFailure: AIUsageFailure?
        for process in processes {
            let endpoints = await Self.endpoints(for: process)
            guard !endpoints.isEmpty else {
                lastFailure = .unavailable("AntiGravity 已打开，但本地额度服务暂不可用。")
                continue
            }

            for endpoint in endpoints {
                do {
                    var snapshot = try await Self.fetchQuotaSummary(from: endpoint)
                    if let identity = try? await Self.fetchUserStatus(from: endpoint),
                       let planName = identity.planName {
                        snapshot.planName = planName
                    }
                    return snapshot
                } catch let failure as AIUsageFailure {
                    lastFailure = failure
                } catch {
                    lastFailure = .unavailable("AntiGravity 暂时未返回可显示额度。")
                }

                do {
                    return try await Self.fetchUserStatus(from: endpoint).snapshot
                } catch let failure as AIUsageFailure {
                    lastFailure = failure
                } catch {
                    lastFailure = .unavailable("AntiGravity 暂时未返回可显示额度。")
                }

                do {
                    return try await Self.fetchCommandModels(from: endpoint)
                } catch let failure as AIUsageFailure {
                    lastFailure = failure
                } catch {
                    lastFailure = .unavailable("AntiGravity 暂时未返回可显示额度。")
                }
            }
        }
        throw lastFailure ?? .unavailable("AntiGravity 暂时未返回可显示额度。")
    }

    static func parseQuotaSummary(data: Data, now: Date) throws -> AIUsageSnapshot {
        let response: QuotaSummaryResponse
        do {
            response = try JSONDecoder().decode(QuotaSummaryResponse.self, from: data)
        } catch {
            throw AIUsageFailure.malformed()
        }
        try validate(response.code)
        let groups = response.response?.groups
            ?? response.summary?.groups
            ?? response.groups
            ?? []

        var metrics: [AIUsageMetric] = []
        for group in groups {
            for bucket in group.buckets ?? [] where bucket.disabled != true {
                guard let remainingFraction = bucket.resolvedRemainingFraction else { continue }
                metrics.append(.quotaWindow(
                    label: metricLabel(group: group.displayName, bucket: bucket.displayName ?? bucket.bucketID),
                    remainingFraction: remainingFraction,
                    resetsAt: bucket.resetTime.flatMap(parseDate)
                ))
            }
        }
        guard !metrics.isEmpty else {
            throw AIUsageFailure.unavailable("AntiGravity 未返回可显示配额。")
        }
        return AIUsageSnapshot(
            providerID: .gemini,
            metrics: metrics,
            planName: nil,
            source: "AntiGravity 本地服务",
            updatedAt: now
        )
    }

    static func parseUserStatus(data: Data, now: Date) throws -> ParsedUserStatus {
        let response: UserStatusResponse
        do {
            response = try JSONDecoder().decode(UserStatusResponse.self, from: data)
        } catch {
            throw AIUsageFailure.malformed()
        }
        try validate(response.code)
        guard let userStatus = response.userStatus else {
            throw AIUsageFailure.malformed()
        }
        let configs = userStatus.cascadeModelConfigData?.clientModelConfigs ?? []
        let planName = userStatus.userTier?.preferredName
            ?? userStatus.planStatus?.planInfo?.preferredName
        return ParsedUserStatus(
            snapshot: try snapshot(from: configs, planName: planName, now: now),
            planName: planName
        )
    }

    static func parseCommandModels(data: Data, now: Date) throws -> AIUsageSnapshot {
        let response: CommandModelConfigResponse
        do {
            response = try JSONDecoder().decode(CommandModelConfigResponse.self, from: data)
        } catch {
            throw AIUsageFailure.malformed()
        }
        try validate(response.code)
        return try snapshot(from: response.clientModelConfigs ?? [], planName: nil, now: now)
    }

    private static let userStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let commandModelsPath = "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"
    private static let quotaSummaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    private static func fetchQuotaSummary(from endpoint: Endpoint) async throws -> AIUsageSnapshot {
        let data = try await request(
            endpoint: endpoint,
            path: quotaSummaryPath,
            body: ["forceRefresh": true]
        )
        return try parseQuotaSummary(data: data, now: .now)
    }

    private static func fetchUserStatus(from endpoint: Endpoint) async throws -> ParsedUserStatus {
        let data = try await request(endpoint: endpoint, path: userStatusPath, body: defaultRequestBody)
        return try parseUserStatus(data: data, now: .now)
    }

    private static func fetchCommandModels(from endpoint: Endpoint) async throws -> AIUsageSnapshot {
        let data = try await request(endpoint: endpoint, path: commandModelsPath, body: defaultRequestBody)
        return try parseCommandModels(data: data, now: .now)
    }

    private static var defaultRequestBody: [String: Any] {
        [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "ideVersion": "unknown",
                "locale": "zh-CN",
            ],
        ]
    }

    private static func request(
        endpoint: Endpoint,
        path: String,
        body: [String: Any]
    ) async throws -> Data {
        guard let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(path)") else {
            throw AIUsageFailure.unavailable("AntiGravity 本地额度地址无效。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if !endpoint.csrfToken.isEmpty {
            request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }

        do {
            let (data, response) = try await LocalhostSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIUsageFailure.unavailable("AntiGravity 本地服务响应无效。")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AIUsageFailure.authentication("AntiGravity 登录已失效，请重新登录。")
            }
            guard http.statusCode == 200 else {
                throw AIUsageFailure.unavailable("AntiGravity 本地额度接口暂不可用。")
            }
            return data
        } catch let failure as AIUsageFailure {
            throw failure
        } catch let error as URLError where error.code == .timedOut {
            throw AIUsageFailure.timeout()
        } catch {
            throw AIUsageFailure.unavailable("AntiGravity 本地额度服务暂不可用。")
        }
    }

    private static func endpoints(for process: LocalProcess) async -> [Endpoint] {
        var endpoints: [Endpoint] = []
        if let port = process.extensionPort {
            if let token = process.extensionToken, !token.isEmpty {
                endpoints.append(Endpoint(scheme: "http", port: port, csrfToken: token))
            }
            if process.extensionToken != process.csrfToken {
                endpoints.append(Endpoint(scheme: "http", port: port, csrfToken: process.csrfToken))
            }
        }

        if let output = try? await AIUsageCommandRunner.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-a", "-p", String(process.pid), "-iTCP", "-sTCP:LISTEN"],
            timeout: 3
        ) {
            for port in listeningPorts(from: output) {
                endpoints.append(Endpoint(scheme: "https", port: port, csrfToken: process.csrfToken))
            }
        }

        var seen = Set<String>()
        return endpoints.filter { seen.insert("\($0.scheme):\($0.port):\($0.csrfToken)").inserted }
    }

    static func processes(from output: String) -> [LocalProcess] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let pid = Int(parts[0]) else { return nil }
            let command = String(parts[1])
            let lower = command.lowercased()
            let isLanguageServer = lower.range(
                of: #"(^|[/\\])language(?:_|-)server(?:[_-][a-z0-9]+)*(?:\.exe)?(\s|$)"#,
                options: .regularExpression
            ) != nil
            let isAntiGravity = lower.contains("antigravity.app/")
                || lower.contains("/antigravity/")
                || (lower.contains("--app_data_dir") && lower.contains("antigravity"))
            guard isLanguageServer, isAntiGravity,
                  let csrfToken = extractFlag("--csrf_token", from: command) else {
                return nil
            }
            return LocalProcess(
                pid: pid,
                csrfToken: csrfToken,
                extensionPort: extractFlag("--extension_server_port", from: command).flatMap(Int.init),
                extensionToken: extractFlag("--extension_server_csrf_token", from: command)
            )
        }
    }

    private static func listeningPorts(from output: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var ports = Set<Int>()
        regex.enumerateMatches(in: output, range: range) { match, _, _ in
            guard let match,
                  let valueRange = Range(match.range(at: 1), in: output),
                  let port = Int(output[valueRange]) else { return }
            ports.insert(port)
        }
        return ports.sorted()
    }

    private static func extractFlag(_ flag: String, from command: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: flag)
        guard let regex = try? NSRegularExpression(pattern: "\(escaped)[=\\s]+([^\\s]+)") else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, range: range),
              let valueRange = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[valueRange])
    }

    private static func snapshot(
        from configs: [ModelConfig],
        planName: String?,
        now: Date
    ) throws -> AIUsageSnapshot {
        let quotas = configs.compactMap { config -> ModelQuota? in
            guard let quota = config.quotaInfo,
                  let remainingFraction = quota.remainingFraction else { return nil }
            let identity = [config.label, config.modelOrAlias?.model]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            return ModelQuota(
                identity: identity,
                remainingFraction: remainingFraction,
                resetDate: quota.resetTime.flatMap(parseDate)
            )
        }

        var metrics: [AIUsageMetric] = []
        if let gemini = quotas.filter({ $0.identity.contains("gemini") })
            .min(by: { $0.remainingFraction < $1.remainingFraction }) {
            metrics.append(.quotaWindow(
                label: "Gemini 模型额度",
                remainingFraction: gemini.remainingFraction,
                resetsAt: gemini.resetDate
            ))
        }
        if let other = quotas.filter({ $0.identity.contains("claude") || $0.identity.contains("gpt") })
            .min(by: { $0.remainingFraction < $1.remainingFraction }) {
            metrics.append(.quotaWindow(
                label: "Claude / GPT 模型额度",
                remainingFraction: other.remainingFraction,
                resetsAt: other.resetDate
            ))
        }
        if metrics.isEmpty, let fallback = quotas.min(by: { $0.remainingFraction < $1.remainingFraction }) {
            metrics.append(.quotaWindow(
                label: "模型额度",
                remainingFraction: fallback.remainingFraction,
                resetsAt: fallback.resetDate
            ))
        }
        guard !metrics.isEmpty else {
            throw AIUsageFailure.unavailable("AntiGravity 未返回可显示模型额度。")
        }
        return AIUsageSnapshot(
            providerID: .gemini,
            metrics: metrics,
            planName: planName,
            source: "AntiGravity 本地服务",
            updatedAt: now
        )
    }

    private static func metricLabel(group: String?, bucket: String?) -> String {
        let groupName: String
        let lowerGroup = group?.lowercased() ?? ""
        if lowerGroup.contains("gemini") {
            groupName = "Gemini"
        } else if lowerGroup.contains("claude") || lowerGroup.contains("gpt") {
            groupName = "Claude / GPT"
        } else {
            groupName = group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "模型"
        }

        let lowerBucket = bucket?.lowercased() ?? ""
        let windowName: String
        if lowerBucket.contains("week") || lowerBucket.contains("周") {
            windowName = "周"
        } else if lowerBucket.contains("five") || lowerBucket.contains("5")
            || lowerBucket.contains("session") || lowerBucket.contains("小时") {
            windowName = "5 小时"
        } else {
            windowName = bucket?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "额度"
        }
        return "\(groupName) · \(windowName)"
    }

    private static func validate(_ code: ResponseCode?) throws {
        guard let code, !code.isOK else { return }
        throw AIUsageFailure.unavailable("AntiGravity 本地额度接口暂不可用。")
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        guard let number = Double(value) else { return nil }
        return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
    }
}

extension AntiGravityUsageProvider {
    struct LocalProcess: Equatable {
        var pid: Int
        var csrfToken: String
        var extensionPort: Int?
        var extensionToken: String?
    }

    struct ParsedUserStatus {
        var snapshot: AIUsageSnapshot
        var planName: String?
    }

    private struct Endpoint {
        var scheme: String
        var port: Int
        var csrfToken: String
    }

    private struct ModelQuota {
        var identity: String
        var remainingFraction: Double
        var resetDate: Date?
    }
}

private struct QuotaSummaryResponse: Decodable {
    var code: ResponseCode?
    var response: QuotaSummaryPayload?
    var summary: QuotaSummaryPayload?
    var groups: [QuotaSummaryGroup]?
}

private struct QuotaSummaryPayload: Decodable {
    var groups: [QuotaSummaryGroup]
}

private struct QuotaSummaryGroup: Decodable {
    var displayName: String?
    var buckets: [QuotaSummaryBucket]?
}

private struct QuotaSummaryBucket: Decodable {
    var bucketID: String?
    var displayName: String?
    var disabled: Bool?
    var remainingFraction: Double?
    var remaining: QuotaRemaining?
    var resetTime: String?

    enum CodingKeys: String, CodingKey {
        case bucketID = "bucketId"
        case displayName
        case disabled
        case remainingFraction
        case remaining
        case resetTime
    }

    var resolvedRemainingFraction: Double? {
        remainingFraction ?? remaining?.remainingFraction
    }
}

private struct QuotaRemaining: Decodable {
    var remainingFraction: Double?

    enum CodingKeys: String, CodingKey {
        case remainingFraction
        case oneOfCase = "case"
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
            remainingFraction = direct
        } else if try container.decodeIfPresent(String.self, forKey: .oneOfCase) == "remainingFraction" {
            remainingFraction = try container.decodeIfPresent(Double.self, forKey: .value)
        } else {
            remainingFraction = nil
        }
    }
}

private struct UserStatusResponse: Decodable {
    var code: ResponseCode?
    var userStatus: UserStatus?
}

private struct CommandModelConfigResponse: Decodable {
    var code: ResponseCode?
    var clientModelConfigs: [ModelConfig]?
}

private struct UserStatus: Decodable {
    var planStatus: PlanStatus?
    var cascadeModelConfigData: ModelConfigData?
    var userTier: UserTier?
}

private struct UserTier: Decodable {
    var name: String?

    var preferredName: String? {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private struct PlanStatus: Decodable {
    var planInfo: PlanInfo?
}

private struct PlanInfo: Decodable {
    var planName: String?
    var planDisplayName: String?
    var displayName: String?
    var productName: String?
    var planShortName: String?

    var preferredName: String? {
        [planDisplayName, displayName, productName, planName, planShortName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .first
    }
}

private struct ModelConfigData: Decodable {
    var clientModelConfigs: [ModelConfig]?
}

private struct ModelConfig: Decodable {
    var label: String?
    var modelOrAlias: ModelAlias?
    var quotaInfo: QuotaInfo?
}

private struct ModelAlias: Decodable {
    var model: String?
}

private struct QuotaInfo: Decodable {
    var remainingFraction: Double?
    var resetTime: String?
}

private enum ResponseCode: Decodable {
    case int(Int)
    case string(String)

    var isOK: Bool {
        switch self {
        case .int(let value): value == 0
        case .string(let value): ["0", "ok", "success"].contains(value.lowercased())
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }
}

private final class LocalhostTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private enum LocalhostSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        return URLSession(
            configuration: configuration,
            delegate: LocalhostTrustDelegate(),
            delegateQueue: nil
        )
    }()
}

private enum AIUsageCommandError: Error {
    case startFailed
    case timeout
    case failed
    case outputTooLarge
}

private enum AIUsageCommandRunner {
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            do {
                try process.run()
            } catch {
                throw AIUsageCommandError.startFailed
            }

            let descriptor = outputPipe.fileHandleForReading.fileDescriptor
            let deadline = Date().addingTimeInterval(timeout)
            var output = Data()
            var reachedEOF = false
            while !reachedEOF {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    terminate(process)
                    throw AIUsageCommandError.timeout
                }
                let milliseconds = Int32(min(max(remaining * 1_000, 1), 100))
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let result = Darwin.poll(&pollDescriptor, 1, milliseconds)
                if result < 0 {
                    if errno == EINTR { continue }
                    terminate(process)
                    throw AIUsageCommandError.failed
                }
                if result == 0 {
                    if !process.isRunning { reachedEOF = true }
                    continue
                }

                var bytes = [UInt8](repeating: 0, count: 8_192)
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                }
                if count > 0 {
                    output.append(contentsOf: bytes.prefix(Int(count)))
                    if output.count > 1_048_576 {
                        terminate(process)
                        throw AIUsageCommandError.outputTooLarge
                    }
                } else {
                    reachedEOF = true
                }
            }
            if process.isRunning { process.waitUntilExit() }
            guard process.terminationStatus == 0 else { throw AIUsageCommandError.failed }
            return String(decoding: output, as: UTF8.self)
        }.value
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.3)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
