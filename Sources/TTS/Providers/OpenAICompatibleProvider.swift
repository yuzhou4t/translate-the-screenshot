import Foundation

struct OpenAICompatibleProvider: PromptCompletionProvider {
    let id: TranslationProviderID
    let displayName: String

    private let endpoint: URL
    private let model: String
    private let apiKey: String
    private let timeout: TimeInterval
    private let urlSession: URLSession

    init(
        id: TranslationProviderID = .openAICompatible,
        displayName: String = "OpenAI 兼容接口",
        endpoint: URL,
        model: String,
        apiKey: String,
        timeout: TimeInterval = 30,
        urlSession: URLSession = .shared
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
        self.urlSession = urlSession
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        let prompt = PromptBuilder.build(
            mode: request.translationMode,
            sourceText: request.text,
            targetLanguage: request.targetLanguage
        )
        let translatedText = try await complete(
            systemPrompt: prompt.system,
            userPrompt: prompt.user,
            temperature: 0.2
        )

        return TranslationResponse(
            translatedText: translatedText,
            providerID: id,
            detectedSourceLanguage: nil
        )
    }

    func complete(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double
    ) async throws -> String {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatCompletionRequest(
            model: model,
            messages: [
                .init(
                    role: "system",
                    content: systemPrompt
                ),
                .init(
                    role: "user",
                    content: userPrompt
                )
            ],
            temperature: temperature
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await urlSession.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranslationProviderError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
            }

            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let translatedText = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
                  !translatedText.isEmpty else {
                throw TranslationProviderError.invalidResponse
            }

            return translatedText
        } catch let error as TranslationProviderError {
            throw error
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        } catch {
            throw TranslationProviderError.providerMessage("\(displayName) 请求失败：\(error.localizedDescription)")
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> TranslationProviderError {
        let message = (try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data).error.message) ??
            String(data: data, encoding: .utf8) ??
            "HTTP \(statusCode)"

        switch statusCode {
        case 401, 403:
            return .authenticationFailed("\(displayName) 认证失败，请检查 API Key。")
        case 429:
            return .rateLimited("\(displayName) 请求过于频繁或额度不足，请稍后再试。")
        default:
            return .providerMessage("\(displayName) 请求失败（HTTP \(statusCode)）：\(message)")
        }
    }

    private func mapURLError(_ error: URLError) -> TranslationProviderError {
        switch error.code {
        case .timedOut:
            return .timeout("\(displayName) 请求超时，请稍后再试。")
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .network("网络连接失败，无法访问 \(displayName)。")
        default:
            return .providerMessage("\(displayName) 网络错误：\(error.localizedDescription)")
        }
    }
}

private struct ChatCompletionRequest: Encodable {
    var model: String
    var messages: [ChatMessage]
    var temperature: Double
}

private struct ChatMessage: Codable {
    var role: String
    var content: String
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        var message: ChatMessage
    }

    var choices: [Choice]
}

private struct OpenAIErrorResponse: Decodable {
    struct ProviderError: Decodable {
        var message: String
    }

    var error: ProviderError
}
