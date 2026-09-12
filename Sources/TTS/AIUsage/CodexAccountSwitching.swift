import AppKit
import Combine
import Darwin
import Foundation

// This adapter intentionally reuses the on-disk format created by the MIT-licensed
// Codex Account Switcher project: https://github.com/liuzhao1225/codex-account-switcher
// TTS only exposes already-registered accounts; it never displays or logs auth.json.

struct CodexAccountProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    let email: String?
    let accountID: String?
    let createdAt: Date
    var lastUsedAt: Date?

    var initials: String {
        let value = displayName
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
        return value.isEmpty ? "?" : value.uppercased()
    }
}

struct CodexAccountRegistry: Codable, Equatable, Sendable {
    var activeAccountID: UUID?
    var accounts: [CodexAccountProfile]
}

struct CodexAccountIdentity: Equatable, Sendable {
    let accountID: String?
    let email: String?

    func matches(_ profile: CodexAccountProfile) -> Bool {
        if let expected = profile.accountID, let accountID {
            return expected == accountID
        }
        if let expected = profile.email, let email {
            return expected.caseInsensitiveCompare(email) == .orderedSame
        }
        return false
    }
}

enum CodexAccountSwitchError: LocalizedError, Equatable, Sendable {
    case registryUnavailable
    case profileNotFound
    case activeProfileMissing
    case activeCredentialMissing
    case activeCredentialMismatch
    case targetCredentialMissing
    case unsafeStoragePath
    case credentialTooLarge
    case codexCLIUnavailable
    case identityUnavailable
    case desktopDidNotExit
    case desktopUnavailable
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .registryUnavailable:
            "尚未找到已登记的 Codex 账号。"
        case .profileNotFound:
            "所选 Codex 账号已不存在，请重新打开弹窗。"
        case .activeProfileMissing:
            "账号列表与当前登录状态不一致，请先用原账户切换器修复。"
        case .activeCredentialMissing:
            "当前 Codex 登录凭据不存在，未执行切换。"
        case .activeCredentialMismatch:
            "当前 Codex 登录与 TTS 记录的活跃账号不一致；为避免覆盖凭据，已取消切换。"
        case .targetCredentialMissing:
            "所选账号没有可用的本地登录凭据。"
        case .unsafeStoragePath:
            "账号存储路径不安全，未读取或覆盖任何凭据。"
        case .credentialTooLarge:
            "Codex 登录凭据文件异常，未执行切换。"
        case .codexCLIUnavailable:
            "未检测到 Codex CLI，无法校验账号身份。"
        case .identityUnavailable:
            "Codex 未返回可校验的账号身份。"
        case .desktopDidNotExit:
            "Codex 未在 30 秒内退出。请先处理正在运行的任务，再重试切换。"
        case .desktopUnavailable:
            "未找到可重新打开的 Codex 应用。"
        case .operationFailed(let message):
            message
        }
    }
}

protocol CodexAccountCredentialStoring: Sendable {
    func loadRegistry() async throws -> CodexAccountRegistry
    func profile(id: UUID) async throws -> CodexAccountProfile
    func activeHome() async -> URL
    func saveCurrentCredential() async throws
    func activateCredential(id: UUID) async throws
    func restoreCredential(id: UUID) async throws
    func commitActiveAccountID(_ id: UUID) async throws
}

actor CodexAccountCredentialStore: CodexAccountCredentialStoring {
    let baseURL: URL
    private let activeHomeURL: URL
    private let fileManager: FileManager
    private let maximumCredentialBytes = 4 * 1_024 * 1_024

    init(
        baseURL: URL? = nil,
        activeHomeURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        self.baseURL = baseURL ?? applicationSupport.appendingPathComponent(
            "Codex Account Switcher",
            isDirectory: true
        )
        self.activeHomeURL = activeHomeURL
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private var registryURL: URL { baseURL.appendingPathComponent("accounts.json") }
    private var accountsURL: URL { baseURL.appendingPathComponent("accounts", isDirectory: true) }

    func loadRegistry() throws -> CodexAccountRegistry {
        guard fileManager.fileExists(atPath: registryURL.path) else {
            throw CodexAccountSwitchError.registryUnavailable
        }
        let data = try checkedRegularFileData(registryURL, maximumBytes: 1_024 * 1_024)
        do {
            return try Self.decoder.decode(CodexAccountRegistry.self, from: data)
        } catch {
            throw CodexAccountSwitchError.registryUnavailable
        }
    }

    func profile(id: UUID) throws -> CodexAccountProfile {
        guard let profile = try loadRegistry().accounts.first(where: { $0.id == id }) else {
            throw CodexAccountSwitchError.profileNotFound
        }
        return profile
    }

    func activeHome() -> URL { activeHomeURL }

    func saveCurrentCredential() throws {
        let registry = try loadRegistry()
        guard let activeID = registry.activeAccountID,
              registry.accounts.contains(where: { $0.id == activeID }) else {
            throw CodexAccountSwitchError.activeProfileMissing
        }
        let source = activeHomeURL.appendingPathComponent("auth.json")
        let destination = credentialURL(id: activeID)
        let data = try checkedCredentialData(source, missingError: .activeCredentialMissing)
        try secureAtomicWrite(data, to: destination)
    }

    func activateCredential(id: UUID) throws {
        _ = try profile(id: id)
        let source = credentialURL(id: id)
        let destination = activeHomeURL.appendingPathComponent("auth.json")
        let data = try checkedCredentialData(source, missingError: .targetCredentialMissing)
        try secureAtomicWrite(data, to: destination)
    }

    func restoreCredential(id: UUID) throws {
        try activateCredential(id: id)
    }

    func commitActiveAccountID(_ id: UUID) throws {
        var registry = try loadRegistry()
        guard let index = registry.accounts.firstIndex(where: { $0.id == id }) else {
            throw CodexAccountSwitchError.profileNotFound
        }
        registry.activeAccountID = id
        registry.accounts[index].lastUsedAt = Date()
        let data = try Self.encoder.encode(registry)
        try secureAtomicWrite(data, to: registryURL)
    }

    private func credentialURL(id: UUID) -> URL {
        accountsURL
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    private func checkedCredentialData(
        _ url: URL,
        missingError: CodexAccountSwitchError
    ) throws -> Data {
        guard fileManager.fileExists(atPath: url.path) else { throw missingError }
        return try checkedRegularFileData(url, maximumBytes: maximumCredentialBytes)
    }

    private func checkedRegularFileData(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CodexAccountSwitchError.unsafeStoragePath
        }
        guard let fileSize = values.fileSize, fileSize <= maximumBytes else {
            throw CodexAccountSwitchError.credentialTooLarge
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func secureAtomicWrite(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw CodexAccountSwitchError.unsafeStoragePath
        }
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CodexAccountSwitchError.unsafeStoragePath
            }
        }

        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).tts-\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        buffer.count - offset
                    )
                    guard written > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += written
                }
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Darwin.close(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            _ = Darwin.close(descriptor)
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

protocol CodexAccountIdentityReading: Sendable {
    func readIdentity(profileHome: URL) async throws -> CodexAccountIdentity
}

struct CodexAccountIdentityReader: CodexAccountIdentityReading {
    let binaryPath: String

    func readIdentity(profileHome: URL) async throws -> CodexAccountIdentity {
        try await Task.detached(priority: .userInitiated) {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = profileHome.path
            let session = try AIUsageRPCProcessSession(
                executable: binaryPath,
                arguments: CodexUsageProvider.appServerArguments,
                environment: environment
            )
            defer { session.stop() }
            _ = try session.request(
                method: "initialize",
                params: ["clientInfo": ["name": "tts", "version": "1.0"]],
                timeout: 8
            )
            try session.notify(method: "initialized")
            let result = try session.request(
                method: "account/read",
                params: ["refreshToken": false],
                timeout: 12
            )
            guard let account = result["account"] as? [String: Any] else {
                throw CodexAccountSwitchError.identityUnavailable
            }
            let accountID = account["accountId"] as? String
                ?? account["accountID"] as? String
                ?? account["chatgptAccountId"] as? String
                ?? account["id"] as? String
            let email = account["email"] as? String
            guard accountID != nil || email != nil else {
                throw CodexAccountSwitchError.identityUnavailable
            }
            return CodexAccountIdentity(accountID: accountID, email: email)
        }.value
    }
}

@MainActor
protocol CodexDesktopControlling: Sendable {
    func closeDesktop() async throws
    func reopenDesktop() async throws
}

struct CodexDesktopController: CodexDesktopControlling {
    private let bundleIdentifier = "com.openai.codex"

    func closeDesktop() async throws {
        let applications = runningApplications
        for application in applications where !application.isTerminated {
            guard application.terminate() || application.isTerminated else {
                throw CodexAccountSwitchError.operationFailed("Codex 拒绝了退出请求，未执行切换。")
            }
        }

        let deadline = Date().addingTimeInterval(30)
        while !runningApplications.isEmpty {
            guard Date() < deadline else { throw CodexAccountSwitchError.desktopDidNotExit }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func reopenDesktop() async throws {
        let workspace = NSWorkspace.shared
        let candidates = [
            workspace.urlForApplication(withBundleIdentifier: bundleIdentifier),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/Codex.app"),
        ].compactMap { $0 }
        guard let applicationURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw CodexAccountSwitchError.desktopUnavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await workspace.openApplication(at: applicationURL, configuration: configuration)
        } catch {
            throw CodexAccountSwitchError.operationFailed("账号已切换，但 Codex 未能自动打开；请手动打开 Codex。")
        }
    }

    private var runningApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleIdentifier }
    }
}

protocol CodexAccountSwitchServicing: Sendable {
    func loadRegistry() async throws -> CodexAccountRegistry
    func switchAccount(to targetID: UUID) async throws
}

struct CodexAccountSwitchService: CodexAccountSwitchServicing {
    let store: any CodexAccountCredentialStoring
    let identityReader: any CodexAccountIdentityReading
    let desktop: any CodexDesktopControlling

    func loadRegistry() async throws -> CodexAccountRegistry {
        try await store.loadRegistry()
    }

    func switchAccount(to targetID: UUID) async throws {
        let registry = try await store.loadRegistry()
        guard let activeID = registry.activeAccountID,
              let activeProfile = registry.accounts.first(where: { $0.id == activeID }) else {
            throw CodexAccountSwitchError.activeProfileMissing
        }
        let target = try await store.profile(id: targetID)
        guard target.id != activeID else { return }

        let activeHome = await store.activeHome()
        let currentIdentity = try await identityReader.readIdentity(profileHome: activeHome)
        guard currentIdentity.matches(activeProfile) else {
            throw CodexAccountSwitchError.activeCredentialMismatch
        }

        try await desktop.closeDesktop()
        do {
            let settledIdentity = try await identityReader.readIdentity(profileHome: activeHome)
            guard settledIdentity.matches(activeProfile) else {
                throw CodexAccountSwitchError.activeCredentialMismatch
            }
            try await store.saveCurrentCredential()
            try await store.activateCredential(id: targetID)

            let targetIdentity = try await identityReader.readIdentity(profileHome: activeHome)
            guard targetIdentity.matches(target) else {
                throw CodexAccountSwitchError.identityUnavailable
            }
            try await store.commitActiveAccountID(targetID)
        } catch {
            try? await store.restoreCredential(id: activeID)
            try? await desktop.reopenDesktop()
            throw error
        }

        try await desktop.reopenDesktop()
    }
}

@MainActor
final class CodexAccountSwitcherStore: ObservableObject {
    @Published private(set) var accounts: [CodexAccountProfile] = []
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var switchingAccountID: UUID?
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false

    private let service: any CodexAccountSwitchServicing
    private let onDidSwitch: @MainActor @Sendable () async -> Void

    init(
        service: (any CodexAccountSwitchServicing)? = nil,
        onDidSwitch: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        if let service {
            self.service = service
        } else if let binaryPath = AIUsageBinaryLocator.codexBinary() {
            let credentialStore = CodexAccountCredentialStore()
            self.service = CodexAccountSwitchService(
                store: credentialStore,
                identityReader: CodexAccountIdentityReader(binaryPath: binaryPath),
                desktop: CodexDesktopController()
            )
        } else {
            self.service = UnavailableCodexAccountSwitchService()
        }
        self.onDidSwitch = onDidSwitch
    }

    var isAvailable: Bool { !accounts.isEmpty }
    var isSwitching: Bool { switchingAccountID != nil }

    func reload() {
        guard !isLoading, !isSwitching else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let registry = try await service.loadRegistry()
                accounts = registry.accounts
                activeAccountID = registry.activeAccountID
                statusMessage = nil
                statusIsError = false
            } catch {
                accounts = []
                activeAccountID = nil
                statusMessage = error.localizedDescription
                statusIsError = true
            }
        }
    }

    func switchAccount(to id: UUID) {
        guard id != activeAccountID, switchingAccountID == nil else { return }
        switchingAccountID = id
        statusMessage = "正在安全切换 Codex 账号…"
        statusIsError = false
        Task {
            defer { switchingAccountID = nil }
            do {
                try await service.switchAccount(to: id)
                let registry = try await service.loadRegistry()
                accounts = registry.accounts
                activeAccountID = registry.activeAccountID
                statusMessage = "Codex 账号已切换并重新打开。"
                statusIsError = false
                await onDidSwitch()
            } catch {
                statusMessage = error.localizedDescription
                statusIsError = true
            }
        }
    }
}

private struct UnavailableCodexAccountSwitchService: CodexAccountSwitchServicing {
    func loadRegistry() async throws -> CodexAccountRegistry {
        throw CodexAccountSwitchError.codexCLIUnavailable
    }

    func switchAccount(to targetID: UUID) async throws {
        _ = targetID
        throw CodexAccountSwitchError.codexCLIUnavailable
    }
}
