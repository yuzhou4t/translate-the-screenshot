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

struct CodexAccountAuthorization: Sendable {
    let identity: CodexAccountIdentity
    let credential: Data
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
    case credentialExpired
    case authorizationAccountMismatch(String)
    case authorizationUnavailable
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
        case .credentialExpired:
            "该 Codex 账号的登录已失效，请重新登录并登记该账号后再切换。"
        case .authorizationAccountMismatch(let displayName):
            "浏览器登录的不是 \(displayName)，未覆盖该账号的保存凭据。请重试并选择正确账号。"
        case .authorizationUnavailable:
            "无法打开 Codex 登录页面，请检查默认浏览器后重试。"
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
    func profileHome(id: UUID) async -> URL
    func saveCurrentCredential() async throws
    func installCredential(_ data: Data, id: UUID) async throws
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

    func profileHome(id: UUID) -> URL {
        accountsURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

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

    func installCredential(_ data: Data, id: UUID) throws {
        _ = try profile(id: id)
        guard data.count <= maximumCredentialBytes else {
            throw CodexAccountSwitchError.credentialTooLarge
        }
        try secureAtomicWrite(data, to: credentialURL(id: id))
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
    func readIdentity(
        profileHome: URL,
        validateSession: Bool
    ) async throws -> CodexAccountIdentity
    func authorize() async throws -> CodexAccountAuthorization
}

struct CodexAccountIdentityReader: CodexAccountIdentityReading {
    let binaryPath: String

    func readIdentity(
        profileHome: URL,
        validateSession: Bool
    ) async throws -> CodexAccountIdentity {
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
            let identity = try Self.parseIdentity(result)
            if validateSession {
                try Self.validateSession(session)
            }
            return identity
        }.value
    }

    func authorize() async throws -> CodexAccountAuthorization {
        do {
            return try await Task.detached(priority: .userInitiated) {
                let fileManager = FileManager.default
                let profileHome = fileManager.temporaryDirectory.appendingPathComponent(
                    "tts-codex-login-\(UUID().uuidString)",
                    isDirectory: true
                )
                try fileManager.createDirectory(
                    at: profileHome,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                defer { try? fileManager.removeItem(at: profileHome) }

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
                let start = try session.request(
                    method: "account/login/start",
                    params: [
                        "type": "chatgpt",
                        "useHostedLoginSuccessPage": true,
                        "appBrand": "codex",
                    ],
                    timeout: 12
                )
                guard let authURLString = start["authUrl"] as? String,
                      let rawAuthURL = URL(string: authURLString)
                else {
                    throw CodexAccountSwitchError.authorizationUnavailable
                }
                let authURL = Self.loginURLRequiringAccountChoice(rawAuthURL)
                let didOpen = await MainActor.run { NSWorkspace.shared.open(authURL) }
                guard didOpen else {
                    throw CodexAccountSwitchError.authorizationUnavailable
                }

                let completion = try session.waitForNotification(
                    method: "account/login/completed",
                    timeout: 600
                )
                guard completion["success"] as? Bool == true else {
                    throw CodexAccountSwitchError.operationFailed(
                        "Codex 账号登录未完成，请重试。"
                    )
                }
                let result = try session.request(
                    method: "account/read",
                    params: ["refreshToken": false],
                    timeout: 12
                )
                let identity = try Self.parseIdentity(result)
                try Self.validateSession(session)

                let credentialURL = profileHome.appendingPathComponent("auth.json")
                let values = try credentialURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw CodexAccountSwitchError.unsafeStoragePath
                }
                guard let fileSize = values.fileSize, fileSize <= 4 * 1_024 * 1_024 else {
                    throw CodexAccountSwitchError.credentialTooLarge
                }
                let credential = try Data(contentsOf: credentialURL, options: .mappedIfSafe)
                return CodexAccountAuthorization(identity: identity, credential: credential)
            }.value
        } catch AIUsageRPCError.timeout {
            throw CodexAccountSwitchError.operationFailed(
                "等待浏览器登录超时，未修改任何已保存账号。请重试。"
            )
        } catch AIUsageRPCError.requestFailed {
            throw CodexAccountSwitchError.operationFailed(
                "Codex 账号登录失败，未修改任何已保存账号。请重试。"
            )
        } catch let error as CodexAccountSwitchError {
            throw error
        } catch {
            throw CodexAccountSwitchError.operationFailed(
                "无法完成 Codex 账号登录，未修改任何已保存账号。请重试。"
            )
        }
    }

    private static func parseIdentity(_ result: [String: Any]) throws -> CodexAccountIdentity {
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
    }

    static func loginURLRequiringAccountChoice(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("prompt") == .orderedSame }
        // Codex's generated URL has no prompt parameter, so Safari can silently
        // reuse the current ChatGPT cookie. Requiring a fresh login lets the user
        // deliberately choose the saved target account.
        queryItems.append(URLQueryItem(name: "prompt", value: "login"))
        components.queryItems = queryItems
        return components.url ?? url
    }

    private static func validateSession(_ session: AIUsageRPCProcessSession) throws {
        do {
            // account/read can decode an expired local token without proving that
            // the saved session is still accepted by the service. A lightweight
            // authenticated request prevents a revoked profile from being reported
            // as a successful account switch.
            _ = try session.request(
                method: "account/rateLimits/read",
                timeout: 12
            )
        } catch AIUsageRPCError.requestFailed(let message) {
            let normalized = message.lowercased()
            if normalized.contains("401")
                || normalized.contains("auth")
                || normalized.contains("login")
                || normalized.contains("log in")
                || normalized.contains("sign in")
                || normalized.contains("token")
                || normalized.contains("revoked") {
                throw CodexAccountSwitchError.credentialExpired
            }
            throw CodexAccountSwitchError.operationFailed(
                "暂时无法在线验证 Codex 账号，请稍后重试。"
            )
        } catch let error as CodexAccountSwitchError {
            throw error
        } catch {
            throw CodexAccountSwitchError.operationFailed(
                "暂时无法在线验证 Codex 账号，请稍后重试。"
            )
        }
    }
}

@MainActor
protocol CodexDesktopControlling: Sendable {
    func closeDesktop() async throws
    func reopenDesktop() async throws
}

struct CodexDesktopController: CodexDesktopControlling {
    // Explicitly request a local Codex task. A bare launch/new-task URL inherits
    // the desktop app's last selected product and can reopen ChatGPT Work instead.
    static let codexEntryURL = URL(string: "codex://threads/new?mode=local")!

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
            let application = try await workspace.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            let readyDeadline = Date().addingTimeInterval(5)
            while !application.isFinishedLaunching, Date() < readyDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(300))
            guard workspace.open(Self.codexEntryURL) else {
                throw CodexAccountSwitchError.desktopUnavailable
            }
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
        var registry = try await store.loadRegistry()
        let activeHome = await store.activeHome()
        guard let identity = try? await identityReader.readIdentity(
            profileHome: activeHome,
            validateSession: false
        ) else {
            registry.activeAccountID = nil
            return registry
        }
        registry.activeAccountID = registry.accounts.first(where: identity.matches)?.id
        return registry
    }

    func switchAccount(to targetID: UUID) async throws {
        let registry = try await store.loadRegistry()
        let target = try await store.profile(id: targetID)

        let activeHome = await store.activeHome()
        let currentIdentity = try await identityReader.readIdentity(
            profileHome: activeHome,
            validateSession: true
        )
        guard let activeProfile = registry.accounts.first(where: currentIdentity.matches) else {
            throw CodexAccountSwitchError.activeCredentialMismatch
        }
        guard target.id != activeProfile.id else {
            if registry.activeAccountID != activeProfile.id {
                try await store.commitActiveAccountID(activeProfile.id)
            }
            return
        }

        let targetHome = await store.profileHome(id: targetID)
        do {
            let targetIdentity = try await identityReader.readIdentity(
                profileHome: targetHome,
                validateSession: true
            )
            guard targetIdentity.matches(target) else {
                throw CodexAccountSwitchError.identityUnavailable
            }
        } catch CodexAccountSwitchError.credentialExpired {
            let authorization = try await identityReader.authorize()
            guard authorization.identity.matches(target) else {
                throw CodexAccountSwitchError.authorizationAccountMismatch(target.displayName)
            }
            try await store.installCredential(authorization.credential, id: targetID)
            let refreshedIdentity = try await identityReader.readIdentity(
                profileHome: targetHome,
                validateSession: true
            )
            guard refreshedIdentity.matches(target) else {
                throw CodexAccountSwitchError.identityUnavailable
            }
        }

        try await desktop.closeDesktop()
        var didActivateTarget = false
        do {
            let settledIdentity = try await identityReader.readIdentity(
                profileHome: activeHome,
                validateSession: true
            )
            guard settledIdentity.matches(activeProfile) else {
                throw CodexAccountSwitchError.activeCredentialMismatch
            }
            if registry.activeAccountID != activeProfile.id {
                try await store.commitActiveAccountID(activeProfile.id)
            }
            try await store.saveCurrentCredential()
            try await store.activateCredential(id: targetID)
            didActivateTarget = true

            let targetIdentity = try await identityReader.readIdentity(
                profileHome: activeHome,
                validateSession: true
            )
            guard targetIdentity.matches(target) else {
                throw CodexAccountSwitchError.identityUnavailable
            }
            try await store.commitActiveAccountID(targetID)
        } catch {
            if didActivateTarget {
                try? await store.restoreCredential(id: activeProfile.id)
            }
            try? await store.commitActiveAccountID(activeProfile.id)
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
    private let onWillSwitch: @MainActor @Sendable () async -> Void
    private let onDidSwitch: @MainActor @Sendable () async -> Void

    init(
        service: (any CodexAccountSwitchServicing)? = nil,
        onWillSwitch: @escaping @MainActor @Sendable () async -> Void = {},
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
        self.onWillSwitch = onWillSwitch
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
                if activeAccountID == nil {
                    statusMessage = "当前 Codex 登录未匹配到已登记账号。"
                    statusIsError = true
                } else {
                    statusMessage = nil
                    statusIsError = false
                }
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
        statusMessage = "正在校验账号；如登录已失效，会打开浏览器重新登录…"
        statusIsError = false
        Task {
            defer { switchingAccountID = nil }
            do {
                // A persistent Codex translation session keeps the account that
                // was loaded when its app-server process started. Stop it before
                // replacing auth.json so it cannot refresh the old credential
                // back over the newly selected account.
                await onWillSwitch()
                try await service.switchAccount(to: id)
                let registry = try await service.loadRegistry()
                accounts = registry.accounts
                activeAccountID = registry.activeAccountID
                statusMessage = "Codex 登录已切换，并已打开本地 Codex。ChatGPT / 工作账号不会随之切换。"
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
