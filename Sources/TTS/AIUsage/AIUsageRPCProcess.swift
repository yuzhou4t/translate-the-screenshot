import Darwin
import Foundation

enum AIUsageBinaryLocator {
    static let bundledCodexCandidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        NSString(string: "~/Applications/ChatGPT.app/Contents/Resources/codex").expandingTildeInPath,
        "/Applications/Codex.app/Contents/Resources/codex",
    ]

    static func codexBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledCandidates: [String] = bundledCodexCandidates
    ) -> String? {
        firstExecutable(
            named: "codex",
            candidates: bundledCandidates,
            environment: environment,
            preferCandidates: true
        )
    }

    static func grokBinary(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        firstExecutable(
            named: "grok",
            candidates: [NSString(string: "~/.grok/bin/grok").expandingTildeInPath],
            environment: environment
        )
    }

    static func grokAuthFilePath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let root = environment["GROK_HOME"]
            ?? NSString(string: "~/.grok").expandingTildeInPath
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("auth.json")
            .path
    }

    static func antiGravityApplication() -> String? {
        [
            "/Applications/AntiGravity.app",
            "/Applications/Antigravity.app",
            NSString(string: "~/Applications/AntiGravity.app").expandingTildeInPath,
            NSString(string: "~/Applications/Antigravity.app").expandingTildeInPath,
        ].first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private static func firstExecutable(
        named name: String,
        candidates: [String],
        environment: [String: String],
        preferCandidates: Bool = false
    ) -> String? {
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/" + name }
        let orderedCandidates = preferCandidates
            ? candidates + pathCandidates
            : pathCandidates + candidates
        return orderedCandidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }
}

enum AIUsageRPCError: Error {
    case startFailed
    case timeout
    case closed
    case malformed
    case requestFailed(String)
}

final class AIUsageRPCProcessSession {
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private var outputBuffer = Data()
    private var nextID = 1
    private var hasStopped = false

    init(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        do {
            try process.run()
        } catch {
            throw AIUsageRPCError.startFailed
        }
    }

    deinit {
        stop()
    }

    func request(
        method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval
    ) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ])

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let message = try readMessage(deadline: deadline)
            guard let messageID = Self.integerID(message["id"]), messageID == id else {
                continue
            }
            if let error = message["error"] as? [String: Any] {
                throw AIUsageRPCError.requestFailed((error["message"] as? String) ?? "request failed")
            }
            guard let result = message["result"] as? [String: Any] else {
                throw AIUsageRPCError.malformed
            }
            return result
        }
    }

    func notify(method: String, params: [String: Any] = [:]) throws {
        try send([
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ])
    }

    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        try? inputPipe.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()

        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func send(_ payload: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw AIUsageRPCError.malformed
        }
        var data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.withoutEscapingSlashes]
        )
        data.append(0x0A)
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw AIUsageRPCError.closed
        }
    }

    private func readMessage(deadline: Date) throws -> [String: Any] {
        while true {
            if let line = drainLine() {
                guard !line.isEmpty else { continue }
                if let object = try? JSONSerialization.jsonObject(with: line),
                   let message = object as? [String: Any] {
                    return message
                }
                continue
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw AIUsageRPCError.timeout
            }
            let milliseconds = Int32(min(max(remaining * 1_000, 1), Double(Int32.max)))
            var descriptor = pollfd(
                fd: outputPipe.fileHandleForReading.fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, milliseconds)
            if pollResult == 0 {
                throw AIUsageRPCError.timeout
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw AIUsageRPCError.closed
            }

            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    outputPipe.fileHandleForReading.fileDescriptor,
                    buffer.baseAddress,
                    buffer.count
                )
            }
            guard count > 0 else {
                throw AIUsageRPCError.closed
            }
            outputBuffer.append(contentsOf: bytes.prefix(Int(count)))
            guard outputBuffer.count <= 1_048_576 else {
                throw AIUsageRPCError.malformed
            }
        }
    }

    private func drainLine() -> Data? {
        guard let newline = outputBuffer.firstIndex(of: 0x0A) else {
            return nil
        }
        let line = outputBuffer[..<newline]
        outputBuffer.removeSubrange(...newline)
        return Data(line)
    }

    private static func integerID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

enum AIUsageRPCFailureMapper {
    static func map(
        _ error: Error,
        loginMessage: String,
        unavailableMessage: String
    ) -> AIUsageFailure {
        switch error {
        case AIUsageRPCError.timeout:
            return .timeout()
        case AIUsageRPCError.startFailed:
            return .notConfigured(unavailableMessage)
        case AIUsageRPCError.requestFailed(let message):
            let normalized = message.lowercased()
            if normalized.contains("auth") || normalized.contains("login") || normalized.contains("sign in") {
                return .authentication(loginMessage)
            }
            return .unavailable(unavailableMessage)
        case AIUsageRPCError.closed, AIUsageRPCError.malformed:
            return .malformed()
        default:
            return .unavailable(unavailableMessage)
        }
    }
}
