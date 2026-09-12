import Foundation

protocol AIUsageSecretReading: AnyObject {
    func containsAPIKey(account: String) -> Bool
    func loadAPIKey(account: String) throws -> String?
}

extension KeychainService: AIUsageSecretReading {}

@MainActor
protocol AIUsageProviderResolving: AnyObject {
    var descriptors: [AIUsageProviderDescriptor] { get }
    func detectedProviderIDs() -> Set<AIUsageProviderID>
    func configurationStatus(for id: AIUsageProviderID) -> String
    func makeProvider(for id: AIUsageProviderID) throws -> any AIUsageProvider
}

@MainActor
final class AIUsageProviderRegistry: AIUsageProviderResolving {
    static let deepSeekUsageKeyAccount = "usage.deepseek.apiKey"
    static let miniMaxUsageKeyAccount = "usage.minimax.apiKey"

    let descriptors: [AIUsageProviderDescriptor] = [
        .init(id: .codex, setupSummary: "读取本机 ChatGPT 或 Codex CLI 登录态"),
        .init(id: .grok, setupSummary: "复用本机 Grok CLI 登录态读取共享周额度"),
        .init(id: .deepSeek, setupSummary: "使用监控专用 Key，或复用翻译服务 Key"),
        .init(id: .miniMax, setupSummary: "使用 MiniMax Coding Plan API Key"),
        .init(id: .gemini, setupSummary: "读取本机 AntiGravity 登录态与模型配额"),
    ]

    private let settingsStore: AIUsageSettingsStore
    private let keychainService: any AIUsageSecretReading
    private let configurationStore: AppConfigurationStore

    init(
        settingsStore: AIUsageSettingsStore,
        keychainService: any AIUsageSecretReading,
        configurationStore: AppConfigurationStore
    ) {
        self.settingsStore = settingsStore
        self.keychainService = keychainService
        self.configurationStore = configurationStore
    }

    func detectedProviderIDs() -> Set<AIUsageProviderID> {
        var detected = Set<AIUsageProviderID>()
        if AIUsageBinaryLocator.codexBinary() != nil {
            detected.insert(.codex)
        }
        if AIUsageBinaryLocator.grokBinary() != nil,
           FileManager.default.fileExists(atPath: AIUsageBinaryLocator.grokAuthFilePath()) {
            detected.insert(.grok)
        }
        if hasDeepSeekKey() {
            detected.insert(.deepSeek)
        }
        if keychainService.containsAPIKey(account: Self.miniMaxUsageKeyAccount) {
            detected.insert(.miniMax)
        }
        if AIUsageBinaryLocator.antiGravityApplication() != nil {
            detected.insert(.gemini)
        }
        return detected
    }

    func configurationStatus(for id: AIUsageProviderID) -> String {
        switch id {
        case .codex:
            return AIUsageBinaryLocator.codexBinary() == nil ? "未检测到 Codex CLI" : "已检测到 Codex CLI"
        case .grok:
            if AIUsageBinaryLocator.grokBinary() == nil {
                return "未检测到 Grok CLI"
            }
            return FileManager.default.fileExists(atPath: AIUsageBinaryLocator.grokAuthFilePath())
                ? "已检测到 Grok CLI 登录态"
                : "已安装 Grok CLI，但尚未登录"
        case .deepSeek:
            if keychainService.containsAPIKey(account: Self.deepSeekUsageKeyAccount) {
                return "已保存监控专用 Key"
            }
            if settingsStore.settings.deepSeekUsesTranslationKey,
               hasTranslationDeepSeekKey() {
                return "使用翻译服务 Key"
            }
            return "未配置 API Key"
        case .miniMax:
            return keychainService.containsAPIKey(account: Self.miniMaxUsageKeyAccount)
                ? "已保存 Coding Plan Key"
                : "未配置 Coding Plan Key"
        case .gemini:
            return AIUsageBinaryLocator.antiGravityApplication() == nil
                ? "未安装 AntiGravity"
                : "已检测到 AntiGravity；打开后读取本地额度"
        }
    }

    func makeProvider(for id: AIUsageProviderID) throws -> any AIUsageProvider {
        switch id {
        case .codex:
            guard let binary = AIUsageBinaryLocator.codexBinary() else {
                throw AIUsageFailure.notConfigured("未检测到 ChatGPT 或 Codex CLI。")
            }
            return CodexUsageProvider(binaryPath: binary)
        case .grok:
            guard let binary = AIUsageBinaryLocator.grokBinary() else {
                throw AIUsageFailure.notConfigured("未检测到 Grok CLI。")
            }
            return GrokUsageProvider(binaryPath: binary)
        case .deepSeek:
            guard let apiKey = resolvedDeepSeekKey() else {
                throw AIUsageFailure.notConfigured("请配置 DeepSeek 监控 Key，或启用翻译 Key 复用。")
            }
            return DeepSeekUsageProvider(apiKey: apiKey)
        case .miniMax:
            guard let apiKey = key(account: Self.miniMaxUsageKeyAccount) else {
                throw AIUsageFailure.notConfigured("请配置 MiniMax Coding Plan Key。")
            }
            return MiniMaxUsageProvider(
                apiKey: apiKey,
                region: settingsStore.settings.miniMaxRegion
            )
        case .gemini:
            guard AIUsageBinaryLocator.antiGravityApplication() != nil else {
                throw AIUsageFailure.notConfigured("请先安装 AntiGravity。")
            }
            return AntiGravityUsageProvider()
        }
    }

    private func resolvedDeepSeekKey() -> String? {
        if let override = key(account: Self.deepSeekUsageKeyAccount) {
            return override
        }
        guard settingsStore.settings.deepSeekUsesTranslationKey,
              configurationStore.providerConfig(for: .deepSeek) != nil else {
            return nil
        }
        return key(account: TranslationProviderID.deepSeek.rawValue)
    }

    private func hasDeepSeekKey() -> Bool {
        keychainService.containsAPIKey(account: Self.deepSeekUsageKeyAccount)
            || (settingsStore.settings.deepSeekUsesTranslationKey && hasTranslationDeepSeekKey())
    }

    private func hasTranslationDeepSeekKey() -> Bool {
        guard configurationStore.providerConfig(for: .deepSeek) != nil else {
            return false
        }
        return keychainService.containsAPIKey(account: TranslationProviderID.deepSeek.rawValue)
    }

    private func key(account: String) -> String? {
        guard let value = try? keychainService.loadAPIKey(account: account) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
