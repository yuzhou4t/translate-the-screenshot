@testable import TTS
import Foundation

func runTranslationQualityRegressionChecks() async {
    checkChineseTranslationPromptUsesExplicitLanguageName()
    checkTranslationOutputValidationRejectsEnglishNoOp()
    checkTranslationOutputValidationAcceptsChineseTranslation()
    checkTranslationOutputValidationAvoidsIdentifierFalsePositive()
    await checkOpenAICompatibleProviderRetriesInvalidTranslationOnce()
    await checkOpenAICompatibleProviderStopsAfterOneQualityRetry()
    await checkGPTOSSProvidersUseLowReasoningEffort()
    checkCodexSubscriptionConfigurationBoundary()
    await checkCodexSubscriptionProviderUsesLunaAndRetriesInvalidTranslation()
    await checkCodexSubscriptionWarmUpUsesOneShortRequest()
    await checkCodexSubscriptionLiveTranslationWhenEnabled()
}

private func checkChineseTranslationPromptUsesExplicitLanguageName() {
    let prompt = PromptBuilder.build(
        mode: .accurate,
        sourceText: "Please try again.",
        targetLanguage: "zh-CN"
    )

    precondition(prompt.user.contains("Simplified Chinese (zh-CN)"))
    let retryPrompt = PromptBuilder.buildQualityRetry(
        from: prompt,
        targetLanguage: "zh-CN"
    )
    precondition(retryPrompt.system.lowercased().contains("previous response was invalid"))
}

private func checkTranslationOutputValidationRejectsEnglishNoOp() {
    let source = "We had an issue. Please wait a moment and try again."

    precondition(
        TranslationOutputValidator.issue(
            sourceText: source,
            translatedText: source,
            targetLanguage: "zh-CN",
            translationMode: .accurate
        ) == .unchangedSource
    )
    precondition(
        TranslationOutputValidator.issue(
            sourceText: source,
            translatedText: "There was a problem. Please retry shortly.",
            targetLanguage: "zh-CN",
            translationMode: .accurate
        ) == .missingChineseTranslation
    )
}

private func checkTranslationOutputValidationAcceptsChineseTranslation() {
    precondition(
        TranslationOutputValidator.issue(
            sourceText: "Please wait a moment and try again.",
            translatedText: "请稍等片刻，然后重试。",
            targetLanguage: "zh-CN",
            translationMode: .accurate
        ) == nil
    )
    precondition(
        TranslationOutputValidator.issue(
            sourceText: "请稍等片刻。",
            translatedText: "请稍等片刻。",
            targetLanguage: "zh-CN",
            translationMode: .accurate
        ) == nil
    )
}

private func checkTranslationOutputValidationAvoidsIdentifierFalsePositive() {
    precondition(
        TranslationOutputValidator.issue(
            sourceText: "OpenAI API",
            translatedText: "OpenAI API",
            targetLanguage: "zh-CN",
            translationMode: .technical
        ) == nil
    )
}

private func checkOpenAICompatibleProviderRetriesInvalidTranslationOnce() async {
    let source = "We had an issue. Please wait a moment and try again."
    let responses = OpenAITranslationResponseQueue([
        source,
        "我们遇到了问题。请稍等片刻，然后重试。"
    ])
    let provider = makeOpenAITranslationTestProvider(responses: responses)

    let result = try! await provider.translate(
        TranslationRequest(
            text: source,
            sourceLanguage: nil,
            targetLanguage: "zh-CN",
            translationMode: .accurate
        )
    )

    precondition(result.translatedText == "我们遇到了问题。请稍等片刻，然后重试。")
    precondition(responses.requestCount == 2, "invalid output must trigger exactly one retry")
    OpenAITranslationURLProtocolStub.handler = nil
}

private func checkOpenAICompatibleProviderStopsAfterOneQualityRetry() async {
    let source = "Please wait a moment and try again."
    let responses = OpenAITranslationResponseQueue([source, source, "不应请求第三次"])
    let provider = makeOpenAITranslationTestProvider(responses: responses)

    do {
        _ = try await provider.translate(
            TranslationRequest(
                text: source,
                sourceLanguage: nil,
                targetLanguage: "zh-CN",
                translationMode: .accurate
            )
        )
        preconditionFailure("two invalid outputs must fail translation")
    } catch TranslationProviderError.invalidTranslation {
        precondition(responses.requestCount == 2, "quality retry must remain bounded to one retry")
    } catch {
        preconditionFailure("unexpected translation error: \(error)")
    }
    OpenAITranslationURLProtocolStub.handler = nil
}

private func checkGPTOSSProvidersUseLowReasoningEffort() async {
    let providers: [(URL, String, String)] = [
        (URL(string: "https://api.cerebras.ai/v1/chat/completions")!, "gpt-oss-120b", "Cerebras"),
        (URL(string: "https://api.groq.com/openai/v1/chat/completions")!, "openai/gpt-oss-120b", "Groq")
    ]

    for (endpoint, model, name) in providers {
        let responses = OpenAITranslationResponseQueue(["已翻译。"])
        let provider = makeOpenAITranslationTestProvider(
            responses: responses,
            endpoint: endpoint,
            model: model
        )

        _ = try! await provider.translate(
            TranslationRequest(
                text: "Translate this.",
                sourceLanguage: nil,
                targetLanguage: "zh-CN",
                translationMode: .accurate
            )
        )

        precondition(
            responses.requestBodies.allSatisfy { $0.contains("\"reasoning_effort\":\"low\"") },
            "\(name) GPT-OSS requests must use low reasoning effort"
        )
    }
    OpenAITranslationURLProtocolStub.handler = nil
}

private func checkCodexSubscriptionConfigurationBoundary() {
    precondition(CodexSubscriptionProvider.modelID == "gpt-6-luna")
    let configs = AppConfiguration.normalizedConfigs(
        [],
        providerID: .myMemory,
        endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
        model: "gpt-4o-mini"
    )
    let config = configs.first { $0.id == .codexSubscription }

    precondition(config?.type == .codexSubscription)
    precondition(config?.model == CodexSubscriptionProvider.modelID)
    precondition(config?.apiKeyRef == nil, "subscription route must not request an API key")
    precondition(config?.endpoint == nil, "subscription route must not masquerade as an API endpoint")

    var previousConfig = ProviderConfig.codexSubscriptionDefault
    previousConfig.model = "gpt-5.6-luna"
    let migratedConfigs = AppConfiguration.normalizedConfigs(
        [previousConfig],
        providerID: .codexSubscription,
        endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
        model: "gpt-4o-mini"
    )
    precondition(migratedConfigs.first { $0.id == .codexSubscription }?.model == "gpt-6-luna")

    let arguments = CodexSubscriptionClient.appServerArguments
    precondition(arguments.last == "app-server")
    precondition(arguments.contains("read-only"))
    precondition(arguments.contains("shell_tool"))
    precondition(arguments.contains("plugins"))
    precondition(arguments.contains("features.context_management=false"))
    precondition(CodexSubscriptionClient.maxRetainedTurnCount == 32)
    precondition(CodexSubscriptionClient.maxRetainedContextCharacters == 80_000)

    let environment = CodexSubscriptionClient.sanitizedEnvironment([
        "HOME": "/tmp/home",
        "PATH": "/usr/bin",
        "OPENAI_API_KEY": "must-not-cross-process-boundary",
        "UNRELATED_SECRET": "must-not-cross-process-boundary",
    ])
    precondition(environment["HOME"] == "/tmp/home")
    precondition(environment["PATH"] == "/usr/bin")
    precondition(environment["OPENAI_API_KEY"] == nil)
    precondition(environment["UNRELATED_SECRET"] == nil)
}

private func checkCodexSubscriptionProviderUsesLunaAndRetriesInvalidTranslation() async {
    let source = "Please wait a moment and try again."
    let client = CodexTranslationCompletionStub([
        source,
        "请稍等片刻，然后重试。",
    ])
    let provider = CodexSubscriptionProvider(client: client)

    let result = try! await provider.translate(
        TranslationRequest(
            text: source,
            sourceLanguage: nil,
            targetLanguage: "zh-CN",
            translationMode: .accurate
        )
    )
    let calls = await client.capturedCalls()

    precondition(result.providerID == .codexSubscription)
    precondition(result.translatedText == "请稍等片刻，然后重试。")
    precondition(calls.count == 2, "invalid subscription output must trigger exactly one retry")
    precondition(calls.allSatisfy { $0.model == CodexSubscriptionProvider.modelID })
    precondition(calls[1].systemPrompt.lowercased().contains("previous response was invalid"))
}

private func checkCodexSubscriptionWarmUpUsesOneShortRequest() async {
    let client = CodexTranslationCompletionStub(["就绪。"])
    let provider = CodexSubscriptionProvider(client: client)

    try! await provider.warmUp()
    let calls = await client.capturedCalls()

    precondition(calls.count == 1, "Codex warm-up must use exactly one request")
    precondition(calls[0].model == CodexSubscriptionProvider.modelID)
    precondition(calls[0].userPrompt == CodexSubscriptionProvider.warmUpUserPrompt)
    precondition(calls[0].timeout == 30, "Codex warm-up must remain bounded")
}

private func checkCodexSubscriptionLiveTranslationWhenEnabled() async {
    let environment = ProcessInfo.processInfo.environment
    guard (environment["TTS_CODEX_TRANSLATION_LIVE"] == "1"
        || environment["TTS_CODEX_LIVE"] == "1"),
          let executable = AIUsageBinaryLocator.codexBinary() else {
        return
    }

    let client = CodexSubscriptionClient(executable: executable)
    let provider = CodexSubscriptionProvider(client: client)
    let warmUpStart = Date()
    try! await provider.warmUp()
    let warmUpSeconds = Date().timeIntervalSince(warmUpStart)
    let coldStart = Date()
    let first = try! await provider.translate(
        TranslationRequest(
            text: "Please wait a moment and try again.",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            translationMode: .accurate
        )
    )
    let coldSeconds = Date().timeIntervalSince(coldStart)

    let warmStart = Date()
    let second = try! await provider.translate(
        TranslationRequest(
            text: "Residual confounding and reverse causality cannot be ruled out.",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            translationMode: .academic
        )
    )
    let warmSeconds = Date().timeIntervalSince(warmStart)
    await client.stop()

    precondition(first.providerID == .codexSubscription)
    precondition(second.providerID == .codexSubscription)
    precondition(containsHanCharacterForTest(first.translatedText))
    precondition(containsHanCharacterForTest(second.translatedText))
    precondition(first.translatedText.contains("重试") || first.translatedText.contains("再试"))
    precondition(second.translatedText.contains("混杂"))
    precondition(second.translatedText.contains("反向因果"))
    FileHandle.standardError.write(
        Data(
            String(
                format: "Codex subscription live translation: warm-up=%.2fs first-after-warm-up=%.2fs warm=%.2fs\n",
                warmUpSeconds,
                coldSeconds,
                warmSeconds
            ).utf8
        )
    )
}

private func containsHanCharacterForTest(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            true
        default:
            false
        }
    }
}

private func makeOpenAITranslationTestProvider(
    responses: OpenAITranslationResponseQueue,
    endpoint: URL = URL(string: "https://api.cerebras.ai/v1/chat/completions")!,
    model: String = "gpt-oss-120b"
) -> OpenAICompatibleProvider {
    OpenAITranslationURLProtocolStub.handler = { request in
        let content = responses.nextResponse(for: request)
        let data = try JSONSerialization.data(
            withJSONObject: [
                "choices": [
                    ["message": ["role": "assistant", "content": content]]
                ]
            ]
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAITranslationURLProtocolStub.self]
    return OpenAICompatibleProvider(
        endpoint: endpoint,
        model: model,
        apiKey: "test-key",
        urlSession: URLSession(configuration: configuration)
    )
}

private final class OpenAITranslationResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    private var storedRequestBodies: [String] = []

    init(_ responses: [String]) {
        self.responses = responses
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestBodies.count
    }

    var requestBodies: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestBodies
    }

    func nextResponse(for request: URLRequest) -> String {
        lock.lock()
        defer { lock.unlock() }
        storedRequestBodies.append(
            requestBodyString(from: request)
        )
        return responses.isEmpty ? "" : responses.removeFirst()
    }

    private func requestBodyString(from request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8) ?? ""
        }

        guard let stream = request.httpBodyStream else {
            return ""
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private actor CodexTranslationCompletionStub: CodexSubscriptionCompleting {
    struct Call: Sendable {
        var systemPrompt: String
        var userPrompt: String
        var model: String
        var timeout: TimeInterval
    }

    private var responses: [String]
    private var calls: [Call] = []

    init(_ responses: [String]) {
        self.responses = responses
    }

    func complete(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        timeout: TimeInterval
    ) async throws -> String {
        calls.append(
            Call(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: model,
                timeout: timeout
            )
        )
        guard !responses.isEmpty else {
            throw TranslationProviderError.invalidResponse
        }
        return responses.removeFirst()
    }

    func capturedCalls() -> [Call] {
        calls
    }
}

private final class OpenAITranslationURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: (
        @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    )?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
