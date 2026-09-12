import Foundation

struct CodexUsageProvider: AIUsageProvider {
    let id: AIUsageProviderID = .codex
    let binaryPath: String
    static let appServerArguments = [
        "-s", "read-only",
        "-c", "features.context_management=false",
        "app-server",
    ]

    func fetchUsage() async throws -> AIUsageSnapshot {
        do {
            return try await Task.detached(priority: .utility) {
                let session = try AIUsageRPCProcessSession(
                    executable: binaryPath,
                    arguments: Self.appServerArguments
                )
                defer { session.stop() }
                _ = try session.request(
                    method: "initialize",
                    params: ["clientInfo": ["name": "tts", "version": "1.0"]],
                    timeout: 8
                )
                try session.notify(method: "initialized")
                let result = try session.request(
                    method: "account/rateLimits/read",
                    timeout: 12
                )
                return try Self.parse(result: result, now: .now)
            }.value
        } catch let failure as AIUsageFailure {
            throw failure
        } catch {
            throw AIUsageRPCFailureMapper.map(
                error,
                loginMessage: "请先在 ChatGPT 或 Codex CLI 中登录。",
                unavailableMessage: "当前 Codex CLI 无法读取额度。"
            )
        }
    }

    static func parse(result: [String: Any], now: Date) throws -> AIUsageSnapshot {
        let data = try JSONSerialization.data(withJSONObject: result)
        let response: CodexRateLimitsResponse
        do {
            response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        } catch {
            throw AIUsageFailure.malformed()
        }

        var metrics = Self.windowMetrics(for: response.rateLimits)
        for (key, bucket) in response.additionalRateLimits {
            metrics.append(contentsOf: Self.windowMetrics(
                for: bucket,
                labelPrefix: Self.displayName(for: bucket, fallbackID: key)
            ))
        }
        if let credits = response.rateLimits.credits,
           credits.unlimited || credits.balance != nil {
            metrics.append(.amount(
                label: "Credits",
                remaining: credits.balance.flatMap(Double.init),
                limit: nil,
                unit: "Credits",
                resetsAt: nil,
                isUnlimited: credits.unlimited,
                warnsWhenLow: false
            ))
        }

        guard !metrics.isEmpty else {
            throw AIUsageFailure.unavailable("当前 ChatGPT / Codex 账户未返回可显示额度。")
        }
        return AIUsageSnapshot(
            providerID: .codex,
            metrics: metrics,
            planName: response.rateLimits.planType,
            source: "Codex CLI",
            updatedAt: now
        )
    }

    private static func windowLabel(minutes: Int?, fallback: String) -> String {
        guard let minutes else { return fallback }
        if (270...330).contains(minutes) { return "5 小时额度" }
        if (9_000...11_500).contains(minutes) { return "周额度" }
        if minutes >= 40_000 { return "月额度" }
        return fallback
    }

    private static func windowMetrics(
        for rateLimits: CodexRateLimitSnapshot,
        labelPrefix: String? = nil
    ) -> [AIUsageMetric] {
        let windows = [
            (rateLimits.primary, "短时额度"),
            (rateLimits.secondary, "长期额度"),
        ]
        return windows.compactMap { window, fallback in
            guard let window else { return nil }
            let baseLabel = windowLabel(minutes: window.windowDurationMins, fallback: fallback)
            let label = labelPrefix.map { "\($0) · \(baseLabel.replacingOccurrences(of: "额度", with: ""))" }
                ?? baseLabel
            return .quotaWindow(
                label: label,
                remainingFraction: 1 - window.usedPercent / 100,
                resetsAt: window.resetDate
            )
        }
    }

    private static func displayName(
        for rateLimits: CodexRateLimitSnapshot,
        fallbackID: String
    ) -> String {
        let name = rateLimits.limitName ?? rateLimits.limitID ?? fallbackID
        if name.caseInsensitiveCompare("GPT-5.3-Codex-Spark") == .orderedSame {
            return "5.3 Spark"
        }
        return name
    }
}

private struct CodexRateLimitsResponse: Decodable {
    var rateLimits: CodexRateLimitSnapshot
    var rateLimitsByLimitID: [String: CodexRateLimitSnapshot]?

    enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
        case rateLimitsByLimitIDSnake = "rate_limits_by_limit_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimits = try container.decode(CodexRateLimitSnapshot.self, forKey: .rateLimits)
        rateLimitsByLimitID = (try? container.decodeIfPresent(
            [String: CodexRateLimitSnapshot].self,
            forKey: .rateLimitsByLimitID
        )) ?? (try? container.decodeIfPresent(
            [String: CodexRateLimitSnapshot].self,
            forKey: .rateLimitsByLimitIDSnake
        ))
    }

    var additionalRateLimits: [(String, CodexRateLimitSnapshot)] {
        let baseID = rateLimits.limitID ?? "codex"
        return (rateLimitsByLimitID ?? [:])
            .filter { key, bucket in
                key != baseID && bucket.limitID != baseID
            }
            .sorted { lhs, rhs in
                let left = lhs.value.limitName ?? lhs.value.limitID ?? lhs.key
                let right = rhs.value.limitName ?? rhs.value.limitID ?? rhs.key
                return left.localizedStandardCompare(right) == .orderedAscending
            }
    }
}

private struct CodexRateLimitSnapshot: Decodable {
    var primary: CodexRateLimitWindow?
    var secondary: CodexRateLimitWindow?
    var credits: CodexCredits?
    var planType: String?
    var limitID: String?
    var limitName: String?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case credits
        case planType
        case planTypeSnake = "plan_type"
        case limitID = "limitId"
        case limitIDSnake = "limit_id"
        case limitName
        case limitNameSnake = "limit_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primary = try? container.decodeIfPresent(CodexRateLimitWindow.self, forKey: .primary)
        secondary = try? container.decodeIfPresent(CodexRateLimitWindow.self, forKey: .secondary)
        credits = try? container.decodeIfPresent(CodexCredits.self, forKey: .credits)
        planType = (try? container.decodeIfPresent(String.self, forKey: .planType))
            ?? (try? container.decodeIfPresent(String.self, forKey: .planTypeSnake))
        limitID = (try? container.decodeIfPresent(String.self, forKey: .limitID))
            ?? (try? container.decodeIfPresent(String.self, forKey: .limitIDSnake))
        limitName = (try? container.decodeIfPresent(String.self, forKey: .limitName))
            ?? (try? container.decodeIfPresent(String.self, forKey: .limitNameSnake))
    }
}

private struct CodexRateLimitWindow: Decodable {
    var usedPercent: Double
    var windowDurationMins: Int?
    var resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case usedPercentSnake = "used_percent"
        case windowDurationMins
        case windowDurationMinsSnake = "window_duration_mins"
        case resetsAt
        case resetsAtSnake = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = Self.double(container, .usedPercent)
            ?? Self.double(container, .usedPercentSnake)
            ?? 0
        windowDurationMins = Self.int(container, .windowDurationMins)
            ?? Self.int(container, .windowDurationMinsSnake)
        resetsAt = Self.int(container, .resetsAt)
            ?? Self.int(container, .resetsAtSnake)
    }

    var resetDate: Date? {
        resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private static func double(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Double? {
        (try? container.decodeIfPresent(Double.self, forKey: key))
            ?? (try? container.decodeIfPresent(String.self, forKey: key)).flatMap(Double.init)
    }

    private static func int(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Int? {
        (try? container.decodeIfPresent(Int.self, forKey: key))
            ?? (try? container.decodeIfPresent(String.self, forKey: key)).flatMap(Int.init)
    }
}

private struct CodexCredits: Decodable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?
}

struct GrokUsageProvider: AIUsageProvider {
    let id: AIUsageProviderID = .grok
    let binaryPath: String
    let authFilePath: String
    let client: any AIUsageHTTPClient

    init(
        binaryPath: String,
        authFilePath: String = AIUsageBinaryLocator.grokAuthFilePath(),
        client: any AIUsageHTTPClient = URLSessionAIUsageHTTPClient()
    ) {
        self.binaryPath = binaryPath
        self.authFilePath = authFilePath
        self.client = client
    }

    func fetchUsage() async throws -> AIUsageSnapshot {
        do {
            return try await fetchThroughCLI()
        } catch {
            let cliFailure = AIUsageRPCFailureMapper.map(
                error,
                loginMessage: "请先运行 grok login 登录。",
                unavailableMessage: "当前 Grok Build CLI 暂未开放额度读取。"
            )
            do {
                return try await fetchUsingCLILogin()
            } catch let fallbackFailure as AIUsageFailure {
                if fallbackFailure.category == .notConfigured,
                   cliFailure.category != .notConfigured {
                    throw cliFailure
                }
                throw fallbackFailure
            } catch {
                throw cliFailure
            }
        }
    }

    private func fetchThroughCLI() async throws -> AIUsageSnapshot {
        try await Task.detached(priority: .utility) {
            let session = try AIUsageRPCProcessSession(
                executable: binaryPath,
                arguments: ["agent", "stdio"]
            )
            defer { session.stop() }
            _ = try session.request(
                method: "initialize",
                params: [
                    "protocolVersion": "1",
                    "clientCapabilities": [
                        "fs": ["readTextFile": false, "writeTextFile": false],
                        "terminal": false,
                    ],
                ],
                timeout: 8
            )
            let result = try session.request(method: "x.ai/billing", timeout: 12)
            let data = try JSONSerialization.data(withJSONObject: result)
            return try Self.parse(data: data, now: .now, source: "Grok Build CLI")
        }.value
    }

    private func fetchUsingCLILogin() async throws -> AIUsageSnapshot {
        let credentials = try GrokCLIAuthLoader.load(path: authFilePath)
        var components = URLComponents(string: "https://cli-chat-proxy.grok.com/v1/billing")!
        components.queryItems = [URLQueryItem(name: "format", value: "credits")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue(credentials.userID, forHTTPHeaderField: "x-userid")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await client.data(for: request)
            if response.statusCode == 401 || response.statusCode == 403 {
                throw AIUsageFailure.authentication("Grok 登录已失效，请重新运行 grok login。")
            }
            guard (200..<300).contains(response.statusCode) else {
                throw AIUsageFailure.network("暂时无法读取 Grok 共享额度。")
            }
            return try Self.parse(data: data, now: .now, source: "Grok CLI 登录态")
        } catch let failure as AIUsageFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIUsageFailure.network("暂时无法读取 Grok 共享额度。")
        }
    }

    static func parse(
        data: Data,
        now: Date,
        source: String = "Grok CLI 登录态"
    ) throws -> AIUsageSnapshot {
        let response: GrokBillingResponse
        do {
            response = try JSONDecoder().decode(GrokBillingResponse.self, from: data)
        } catch {
            throw AIUsageFailure.malformed()
        }

        let config = response.config
        let metrics: [AIUsageMetric]
        let breakdown: [AIUsageBreakdownItem]?
        if let usedPercent = config?.creditUsagePercent {
            let remaining = 1 - min(max(usedPercent / 100, 0), 1)
            var currentMetrics: [AIUsageMetric] = [
                .quotaWindow(
                    label: config?.currentPeriod?.windowLabel ?? "共享周额度",
                    remainingFraction: remaining,
                    resetsAt: config?.currentPeriod?.endDate
                ),
            ]
            if let prepaid = config?.prepaidBalance?.val, prepaid > 0 {
                currentMetrics.append(.balance(
                    label: "额外 Credits",
                    total: Double(prepaid) / 100,
                    currency: "USD",
                    paid: nil,
                    granted: nil
                ))
            }
            metrics = currentMetrics
            let items = config?.productUsage?.compactMap { item -> AIUsageBreakdownItem? in
                guard let label = item.displayName,
                      let usedFraction = item.usedFraction else { return nil }
                return AIUsageBreakdownItem(label: label, usedFraction: usedFraction)
            } ?? []
            breakdown = items.isEmpty ? nil : items
        } else if let config,
                  config.isUnifiedBillingUser == true || config.currentPeriod != nil {
            // GetGrokCreditsConfig is backed by proto3 JSON. Zero-valued scalars may be
            // omitted, and the official Grok Build client therefore treats a missing
            // creditUsagePercent with no legacy limit as 0% used.
            var currentMetrics: [AIUsageMetric] = [
                .quotaWindow(
                    label: config.currentPeriod?.windowLabel ?? "共享额度",
                    remainingFraction: 1,
                    resetsAt: config.currentPeriod?.endDate
                ),
            ]
            if let prepaid = config.prepaidBalance?.val, prepaid > 0 {
                currentMetrics.append(.balance(
                    label: "额外 Credits",
                    total: Double(prepaid) / 100,
                    currency: "USD",
                    paid: nil,
                    granted: nil
                ))
            }
            metrics = currentMetrics
            breakdown = nil
        } else {
            let limit = config?.monthlyLimit?.val ?? response.monthlyLimit?.val
            let used = config?.used?.val ?? response.usage?.totalUsed?.val
            guard let limit, limit > 0, let used else {
                throw AIUsageFailure.unavailable("当前 Grok 账户未返回共享额度。")
            }
            let remaining = 1 - min(max(Double(used) / Double(limit), 0), 1)
            let period = config?.legacyPeriod ?? response.billingCycle
            metrics = [
                .quotaWindow(
                    label: period?.windowLabel ?? "订阅额度",
                    remainingFraction: remaining,
                    resetsAt: period?.endDate
                ),
            ]
            breakdown = nil
        }

        return AIUsageSnapshot(
            providerID: .grok,
            metrics: metrics,
            planName: response.subscriptionTier ?? "SuperGrok",
            source: source,
            updatedAt: now,
            usageBreakdown: breakdown
        )
    }
}

private struct GrokCLIAuthCredentials: Sendable {
    var accessToken: String
    var userID: String
}

private enum GrokCLIAuthLoader {
    static func load(path: String) throws -> GrokCLIAuthCredentials {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw AIUsageFailure.notConfigured("请先运行 grok login 登录。")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIUsageFailure.authentication("Grok 登录文件无法识别，请重新运行 grok login。")
        }
        let records = object.values.compactMap { $0 as? [String: Any] } + [object]
        for record in records {
            guard let token = Self.nonEmptyString(record["key"]),
                  let userID = Self.nonEmptyString(record["user_id"]) else { continue }
            return GrokCLIAuthCredentials(accessToken: token, userID: userID)
        }
        throw AIUsageFailure.authentication("Grok 登录已失效，请重新运行 grok login。")
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct GrokMoneyValue: Decodable {
    var val: Int
}

private struct GrokBillingUsage: Decodable {
    var totalUsed: GrokMoneyValue?
}

private struct GrokBillingCycle: Decodable {
    var billingPeriodStart: String?
    var billingPeriodEnd: String?

    var startDate: Date? { billingPeriodStart.flatMap(Self.parseDate) }
    var endDate: Date? { billingPeriodEnd.flatMap(Self.parseDate) }

    var windowLabel: String {
        guard let startDate, let endDate else { return "订阅额度" }
        let days = endDate.timeIntervalSince(startDate) / 86_400
        return days <= 8 ? "周额度" : "月额度"
    }

    private static func parseDate(_ value: String) -> Date? {
        AIUsageISO8601.date(from: value)
    }
}

private struct GrokUsagePeriod: Decodable {
    var type: String?
    var start: String?
    var end: String?

    var startDate: Date? { start.flatMap(AIUsageISO8601.date) }
    var endDate: Date? { end.flatMap(AIUsageISO8601.date) }
    var windowLabel: String {
        if type?.uppercased().contains("WEEK") == true { return "共享周额度" }
        guard let startDate, let endDate else { return "共享额度" }
        return endDate.timeIntervalSince(startDate) <= 8 * 86_400 ? "共享周额度" : "共享月额度"
    }
}

private struct GrokProductUsage: Decodable {
    var product: String?
    var usagePercent: Double?

    var usedFraction: Double? {
        usagePercent.map { min(max($0 / 100, 0), 1) }
    }

    var displayName: String? {
        guard let product else { return nil }
        let normalized = product.uppercased()
        if normalized.contains("BUILD") { return "Build" }
        if normalized.contains("CHAT") { return "Chat" }
        if normalized.contains("IMAGINE") { return "Imagine" }
        if normalized.contains("VOICE") { return "Voice" }
        if normalized.contains("API") { return "API" }
        let value = product
            .replacingOccurrences(of: "PRODUCT_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value.capitalized
    }
}

private struct GrokBillingConfig: Decodable {
    var creditUsagePercent: Double?
    var currentPeriod: GrokUsagePeriod?
    var monthlyLimit: GrokMoneyValue?
    var used: GrokMoneyValue?
    var prepaidBalance: GrokMoneyValue?
    var productUsage: [GrokProductUsage]?
    var isUnifiedBillingUser: Bool?
    var billingPeriodStart: String?
    var billingPeriodEnd: String?

    var legacyPeriod: GrokBillingCycle? {
        guard billingPeriodStart != nil || billingPeriodEnd != nil else { return nil }
        return GrokBillingCycle(
            billingPeriodStart: billingPeriodStart,
            billingPeriodEnd: billingPeriodEnd
        )
    }
}

private struct GrokBillingResponse: Decodable {
    var config: GrokBillingConfig?
    var subscriptionTier: String?
    var billingCycle: GrokBillingCycle?
    var monthlyLimit: GrokMoneyValue?
    var usage: GrokBillingUsage?
}

private enum AIUsageISO8601 {
    static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct DeepSeekUsageProvider: AIUsageProvider {
    let id: AIUsageProviderID = .deepSeek
    let apiKey: String
    let client: any AIUsageHTTPClient

    init(apiKey: String, client: any AIUsageHTTPClient = URLSessionAIUsageHTTPClient()) {
        self.apiKey = apiKey
        self.client = client
    }

    func fetchUsage() async throws -> AIUsageSnapshot {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await client.data(for: request)
            if response.statusCode == 401 || response.statusCode == 403 {
                throw AIUsageFailure.authentication("DeepSeek API Key 无效或已失效。")
            }
            guard (200..<300).contains(response.statusCode) else {
                throw AIUsageFailure.network()
            }
            return try Self.parse(data: data, now: .now)
        } catch let failure as AIUsageFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIUsageFailure.network()
        }
    }

    static func parse(data: Data, now: Date) throws -> AIUsageSnapshot {
        let response: DeepSeekBalanceResponse
        do {
            response = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
        } catch {
            throw AIUsageFailure.malformed()
        }
        guard let balance = response.preferredBalance else {
            throw AIUsageFailure.unavailable("DeepSeek 未返回可显示余额。")
        }
        return AIUsageSnapshot(
            providerID: .deepSeek,
            metrics: [
                .balance(
                    label: "API 余额",
                    total: balance.total,
                    currency: balance.currency,
                    paid: balance.paid,
                    granted: balance.granted
                ),
            ],
            planName: response.isAvailable
                ? "Key 有效"
                : (balance.total <= 0 ? "Key 有效 · 余额为 0" : "Key 有效 · API 调用不可用"),
            source: "DeepSeek API",
            updatedAt: now
        )
    }
}

private struct DeepSeekBalanceResponse: Decodable {
    var isAvailable: Bool
    var balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }

    var preferredBalance: (currency: String, total: Double, paid: Double, granted: Double)? {
        let info = balanceInfos.first(where: { $0.currency.uppercased() == "USD" }) ?? balanceInfos.first
        guard let info,
              let total = Double(info.totalBalance),
              let paid = Double(info.toppedUpBalance),
              let granted = Double(info.grantedBalance) else {
            return nil
        }
        return (info.currency, total, paid, granted)
    }
}

private struct DeepSeekBalanceInfo: Decodable {
    var currency: String
    var totalBalance: String
    var grantedBalance: String
    var toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}

struct MiniMaxUsageProvider: AIUsageProvider {
    let id: AIUsageProviderID = .miniMax
    let apiKey: String
    let region: MiniMaxUsageRegion
    let client: any AIUsageHTTPClient

    init(
        apiKey: String,
        region: MiniMaxUsageRegion,
        client: any AIUsageHTTPClient = URLSessionAIUsageHTTPClient()
    ) {
        self.apiKey = apiKey
        self.region = region
        self.client = client
    }

    func fetchUsage() async throws -> AIUsageSnapshot {
        let paths = ["v1/token_plan/remains", "v1/api/openplatform/coding_plan/remains"]
        var lastFailure: AIUsageFailure?
        for path in paths {
            let url = region.apiBaseURL.appendingPathComponent(path)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 12
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await client.data(for: request)
                if response.statusCode == 401 || response.statusCode == 403 {
                    lastFailure = .authentication("MiniMax Coding Plan Key 无效或已失效。")
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    lastFailure = .network()
                    continue
                }
                return try Self.parse(data: data, now: .now)
            } catch let failure as AIUsageFailure {
                lastFailure = failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = .network()
            }
        }
        throw lastFailure ?? .unavailable("MiniMax 未返回 Coding Plan 额度。")
    }

    static func parse(data: Data, now: Date) throws -> AIUsageSnapshot {
        let response: MiniMaxRemainsResponse
        do {
            response = try JSONDecoder().decode(MiniMaxRemainsResponse.self, from: data)
        } catch {
            throw AIUsageFailure.malformed()
        }
        if let statusCode = response.baseResponse?.statusCode, statusCode != 0 {
            if statusCode == 1004 {
                throw AIUsageFailure.authentication("MiniMax Coding Plan Key 无效或已失效。")
            }
            throw AIUsageFailure.unavailable("MiniMax 暂时无法返回 Coding Plan 额度。")
        }
        guard let general = response.payload.modelRemains.first(where: { ($0.modelName ?? "general") == "general" })
            ?? response.payload.modelRemains.first else {
            throw AIUsageFailure.unavailable("MiniMax 未返回文本 Coding Plan 额度。")
        }

        var metrics: [AIUsageMetric] = []
        if general.currentIntervalStatus != 3,
           let remaining = general.intervalRemainingFraction {
            metrics.append(.quotaWindow(
                label: "5 小时额度",
                remainingFraction: remaining,
                resetsAt: general.intervalEndDate
            ))
        }
        if general.currentWeeklyStatus != 3,
           let remaining = general.weeklyRemainingFraction {
            metrics.append(.quotaWindow(
                label: "周额度",
                remainingFraction: remaining,
                resetsAt: general.weeklyEndDate
            ))
        } else if general.currentWeeklyStatus == 3 {
            metrics.append(.amount(
                label: "周额度",
                remaining: nil,
                limit: nil,
                unit: "",
                resetsAt: nil,
                isUnlimited: true,
                warnsWhenLow: true
            ))
        }
        guard !metrics.isEmpty else {
            throw AIUsageFailure.unavailable("MiniMax 未返回可显示 Coding Plan 额度。")
        }
        return AIUsageSnapshot(
            providerID: .miniMax,
            metrics: metrics,
            planName: response.payload.currentSubscribeTitle ?? "Coding Plan",
            source: "MiniMax API",
            updatedAt: now
        )
    }
}

private struct MiniMaxBaseResponse: Decodable {
    var statusCode: Int?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statusCode = (try? container.decodeIfPresent(Int.self, forKey: .statusCode))
            ?? (try? container.decodeIfPresent(String.self, forKey: .statusCode)).flatMap(Int.init)
    }
}

private struct MiniMaxRemainsPayload: Decodable {
    var currentSubscribeTitle: String?
    var modelRemains: [MiniMaxModelRemains]

    enum CodingKeys: String, CodingKey {
        case currentSubscribeTitle = "current_subscribe_title"
        case modelRemains = "model_remains"
    }

    init(currentSubscribeTitle: String?, modelRemains: [MiniMaxModelRemains]) {
        self.currentSubscribeTitle = currentSubscribeTitle
        self.modelRemains = modelRemains
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentSubscribeTitle = try? container.decodeIfPresent(String.self, forKey: .currentSubscribeTitle)
        modelRemains = (try? container.decodeIfPresent([MiniMaxModelRemains].self, forKey: .modelRemains)) ?? []
    }
}

private struct MiniMaxRemainsResponse: Decodable {
    var baseResponse: MiniMaxBaseResponse?
    var payload: MiniMaxRemainsPayload

    enum CodingKeys: String, CodingKey {
        case baseResponse = "base_resp"
        case data
        case currentSubscribeTitle = "current_subscribe_title"
        case modelRemains = "model_remains"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseResponse = try? container.decodeIfPresent(MiniMaxBaseResponse.self, forKey: .baseResponse)
        if let nested = try? container.decodeIfPresent(MiniMaxRemainsPayload.self, forKey: .data) {
            payload = nested
        } else {
            payload = MiniMaxRemainsPayload(
                currentSubscribeTitle: try? container.decodeIfPresent(String.self, forKey: .currentSubscribeTitle),
                modelRemains: (try? container.decodeIfPresent([MiniMaxModelRemains].self, forKey: .modelRemains)) ?? []
            )
        }
    }
}

private struct MiniMaxModelRemains: Decodable {
    var modelName: String?
    var currentIntervalTotalCount: Double?
    var currentIntervalUsageCount: Double?
    var currentIntervalRemainingPercent: Double?
    var currentIntervalStatus: Int?
    var endTime: Double?
    var currentWeeklyTotalCount: Double?
    var currentWeeklyUsageCount: Double?
    var currentWeeklyRemainingPercent: Double?
    var currentWeeklyStatus: Int?
    var weeklyEndTime: Double?

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case currentIntervalTotalCount = "current_interval_total_count"
        case currentIntervalUsageCount = "current_interval_usage_count"
        case currentIntervalRemainingPercent = "current_interval_remaining_percent"
        case currentIntervalStatus = "current_interval_status"
        case endTime = "end_time"
        case currentWeeklyTotalCount = "current_weekly_total_count"
        case currentWeeklyUsageCount = "current_weekly_usage_count"
        case currentWeeklyRemainingPercent = "current_weekly_remaining_percent"
        case currentWeeklyStatus = "current_weekly_status"
        case weeklyEndTime = "weekly_end_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelName = try? container.decodeIfPresent(String.self, forKey: .modelName)
        currentIntervalTotalCount = Self.double(container, .currentIntervalTotalCount)
        currentIntervalUsageCount = Self.double(container, .currentIntervalUsageCount)
        currentIntervalRemainingPercent = Self.double(container, .currentIntervalRemainingPercent)
        currentIntervalStatus = Self.int(container, .currentIntervalStatus)
        endTime = Self.double(container, .endTime)
        currentWeeklyTotalCount = Self.double(container, .currentWeeklyTotalCount)
        currentWeeklyUsageCount = Self.double(container, .currentWeeklyUsageCount)
        currentWeeklyRemainingPercent = Self.double(container, .currentWeeklyRemainingPercent)
        currentWeeklyStatus = Self.int(container, .currentWeeklyStatus)
        weeklyEndTime = Self.double(container, .weeklyEndTime)
    }

    var intervalRemainingFraction: Double? {
        remainingFraction(
            explicitPercent: currentIntervalRemainingPercent,
            total: currentIntervalTotalCount,
            used: currentIntervalUsageCount
        )
    }

    var weeklyRemainingFraction: Double? {
        remainingFraction(
            explicitPercent: currentWeeklyRemainingPercent,
            total: currentWeeklyTotalCount,
            used: currentWeeklyUsageCount
        )
    }

    var intervalEndDate: Date? { Self.date(milliseconds: endTime) }
    var weeklyEndDate: Date? { Self.date(milliseconds: weeklyEndTime) }

    private func remainingFraction(explicitPercent: Double?, total: Double?, used: Double?) -> Double? {
        if let explicitPercent {
            return min(max(explicitPercent / 100, 0), 1)
        }
        guard let total, total > 0, let used else { return nil }
        return min(max((total - used) / total, 0), 1)
    }

    private static func date(milliseconds: Double?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: $0 > 10_000_000_000 ? $0 / 1_000 : $0) }
    }

    private static func double(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Double? {
        (try? container.decodeIfPresent(Double.self, forKey: key))
            ?? (try? container.decodeIfPresent(String.self, forKey: key)).flatMap(Double.init)
    }

    private static func int(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Int? {
        (try? container.decodeIfPresent(Int.self, forKey: key))
            ?? (try? container.decodeIfPresent(String.self, forKey: key)).flatMap(Int.init)
    }
}

struct GeminiUsageProvider: AIUsageProvider {
    let id: AIUsageProviderID = .gemini
    let binaryPath: String
    let credentialsPath: String
    let client: any AIUsageHTTPClient

    init(
        binaryPath: String,
        credentialsPath: String = NSString(string: "~/.gemini/oauth_creds.json").expandingTildeInPath,
        client: any AIUsageHTTPClient = URLSessionAIUsageHTTPClient()
    ) {
        self.binaryPath = binaryPath
        self.credentialsPath = credentialsPath
        self.client = client
    }

    func fetchUsage() async throws -> AIUsageSnapshot {
        let credentials: GeminiOAuthCredentials
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: credentialsPath))
            credentials = try JSONDecoder().decode(GeminiOAuthCredentials.self, from: data)
        } catch {
            throw AIUsageFailure.notConfigured("请先安装 Gemini CLI 并完成 OAuth 登录。")
        }

        let accessToken = try await resolvedAccessToken(credentials)
        let codeAssist = try await loadCodeAssist(accessToken: accessToken)
        let quota = try await loadQuota(accessToken: accessToken, projectID: codeAssist.projectID)
        return try Self.parseQuota(
            data: quota,
            planName: codeAssist.planName,
            now: .now
        )
    }

    static func parseQuota(data: Data, planName: String?, now: Date) throws -> AIUsageSnapshot {
        let response: GeminiQuotaResponse
        do {
            response = try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        } catch {
            throw AIUsageFailure.malformed()
        }

        let pro = response.buckets
            .filter { $0.modelID.lowercased().contains("pro") }
            .min(by: { $0.remainingFraction < $1.remainingFraction })
        let flash = response.buckets
            .filter { $0.modelID.lowercased().contains("flash") }
            .min(by: { $0.remainingFraction < $1.remainingFraction })

        var metrics: [AIUsageMetric] = []
        if let pro {
            metrics.append(.quotaWindow(
                label: "Pro 模型额度",
                remainingFraction: pro.remainingFraction,
                resetsAt: pro.resetDate
            ))
        }
        if let flash {
            metrics.append(.quotaWindow(
                label: "Flash 模型额度",
                remainingFraction: flash.remainingFraction,
                resetsAt: flash.resetDate
            ))
        }
        guard !metrics.isEmpty else {
            throw AIUsageFailure.unavailable("Gemini CLI 未返回可显示配额。")
        }
        return AIUsageSnapshot(
            providerID: .gemini,
            metrics: metrics,
            planName: planName,
            source: "Gemini CLI OAuth",
            updatedAt: now
        )
    }

    private func resolvedAccessToken(_ credentials: GeminiOAuthCredentials) async throws -> String {
        if let expiry = credentials.expiryDate,
           expiry.timeIntervalSinceNow > 60,
           !credentials.accessToken.isEmpty {
            return credentials.accessToken
        }
        guard let refreshToken = credentials.refreshToken,
              let oauthClient = GeminiOAuthClientLocator.locate(binaryPath: binaryPath) else {
            throw AIUsageFailure.authentication("Gemini CLI 登录已过期，请重新运行 gemini 登录。")
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "client_id": oauthClient.clientID,
            "client_secret": oauthClient.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ].formURLEncodedData

        do {
            let (data, response) = try await client.data(for: request)
            guard (200..<300).contains(response.statusCode),
                  let token = try? JSONDecoder().decode(GeminiRefreshResponse.self, from: data).accessToken,
                  !token.isEmpty else {
                throw AIUsageFailure.authentication("Gemini CLI 登录已过期，请重新运行 gemini 登录。")
            }
            return token
        } catch let failure as AIUsageFailure {
            throw failure
        } catch {
            throw AIUsageFailure.network()
        }
    }

    private func loadCodeAssist(accessToken: String) async throws -> GeminiCodeAssistStatus {
        var request = URLRequest(
            url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"],
        ])
        do {
            let (data, response) = try await client.data(for: request)
            try Self.validateGeminiResponse(data: data, response: response)
            let payload = try JSONDecoder().decode(GeminiCodeAssistResponse.self, from: data)
            return GeminiCodeAssistStatus(
                projectID: payload.projectID,
                planName: payload.paidTier?.name ?? payload.currentTier?.displayName
            )
        } catch let failure as AIUsageFailure {
            throw failure
        } catch {
            throw AIUsageFailure.network()
        }
    }

    private func loadQuota(accessToken: String, projectID: String?) async throws -> Data {
        var request = URLRequest(
            url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = projectID.map { ["project": $0] } ?? [:]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await client.data(for: request)
            try Self.validateGeminiResponse(data: data, response: response)
            return data
        } catch let failure as AIUsageFailure {
            throw failure
        } catch {
            throw AIUsageFailure.network()
        }
    }

    private static func validateGeminiResponse(data: Data, response: HTTPURLResponse) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        if text.contains("unsupported_client") || text.contains("ineligibletiererror") {
            throw AIUsageFailure.unavailable("当前个人 Gemini 订阅不再提供 Gemini CLI 配额。")
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw AIUsageFailure.authentication("Gemini CLI 登录已失效，请重新登录。")
        }
        throw AIUsageFailure.network()
    }
}

private struct GeminiOAuthCredentials: Decodable {
    var accessToken: String
    var refreshToken: String?
    var expiryMilliseconds: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiryMilliseconds = "expiry_date"
    }

    var expiryDate: Date? {
        expiryMilliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) }
    }
}

private struct GeminiRefreshResponse: Decodable {
    var accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private struct GeminiTier: Decodable {
    var id: String?
    var name: String?

    var displayName: String? {
        name ?? id?.replacingOccurrences(of: "-tier", with: "").capitalized
    }
}

private struct GeminiCodeAssistResponse: Decodable {
    var currentTier: GeminiTier?
    var paidTier: GeminiTier?
    var projectValue: GeminiProjectValue?

    enum CodingKeys: String, CodingKey {
        case currentTier
        case paidTier
        case projectValue = "cloudaicompanionProject"
    }

    var projectID: String? {
        projectValue?.id
    }
}

private enum GeminiProjectValue: Decodable {
    case string(String)
    case object(String?)

    var id: String? {
        switch self {
        case .string(let value): value
        case .object(let value): value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        let object = try container.decode([String: String].self)
        self = .object(object["id"] ?? object["projectId"])
    }
}

private struct GeminiCodeAssistStatus {
    var projectID: String?
    var planName: String?
}

private struct GeminiQuotaBucket: Decodable {
    var modelID: String
    var remainingFraction: Double
    var resetTime: String?

    enum CodingKeys: String, CodingKey {
        case modelID = "modelId"
        case remainingFraction
        case resetTime
    }

    var resetDate: Date? {
        resetTime.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

private struct GeminiQuotaResponse: Decodable {
    var buckets: [GeminiQuotaBucket]
}

private struct GeminiOAuthClient {
    var clientID: String
    var clientSecret: String
}

private enum GeminiOAuthClientLocator {
    static func locate(binaryPath: String) -> GeminiOAuthClient? {
        let environment = ProcessInfo.processInfo.environment
        if let clientID = environment["GEMINI_OAUTH_CLIENT_ID"],
           let clientSecret = environment["GEMINI_OAUTH_CLIENT_SECRET"],
           !clientID.isEmpty,
           !clientSecret.isEmpty {
            return GeminiOAuthClient(clientID: clientID, clientSecret: clientSecret)
        }

        let resolvedBinary = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
        let prefixes = [
            resolvedBinary.deletingLastPathComponent(),
            resolvedBinary.deletingLastPathComponent().deletingLastPathComponent(),
            URL(fileURLWithPath: "/opt/homebrew/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/@google/gemini-cli"),
        ]
        let relatives = [
            "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "../lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
        ]
        for prefix in prefixes {
            for relative in relatives {
                let url = prefix.appendingPathComponent(relative).standardizedFileURL
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let clientID = capture(named: "OAUTH_CLIENT_ID", in: text),
                      let clientSecret = capture(named: "OAUTH_CLIENT_SECRET", in: text) else {
                    continue
                }
                return GeminiOAuthClient(clientID: clientID, clientSecret: clientSecret)
            }
        }
        return nil
    }

    private static func capture(named name: String, in text: String) -> String? {
        let pattern = "\\b\(name)\\b\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}

private extension Dictionary where Key == String, Value == String {
    var formURLEncodedData: Data {
        map { key, value in
            "\(key.formURLEncoded)=\(value.formURLEncoded)"
        }
        .sorted()
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
    }
}

private extension String {
    var formURLEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }
}
