import AppKit
import Foundation

struct GeminiProvider: PromptCompletionProvider, VisionSegmentationProvider {
    let id: TranslationProviderID
    let displayName: String

    private let endpoint: URL?
    private let model: String
    private let apiKey: String
    private let timeout: TimeInterval
    private let urlSession: URLSession

    init(
        id: TranslationProviderID = .gemini,
        displayName: String = "Gemini",
        endpoint: URL?,
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

    var supportsVisionInput: Bool {
        true
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
        let body = GeminiGenerateContentRequest(
            contents: [
                .init(
                    role: "user",
                    parts: [
                        .text(combinedPrompt(systemPrompt: systemPrompt, userPrompt: userPrompt))
                    ]
                )
            ],
            generationConfig: .init(
                temperature: temperature,
                responseMimeType: nil
            )
        )
        return try await performGenerateContentRequest(body)
    }

    func completeVisionSegmentation(
        systemPrompt: String,
        userPrompt: String,
        image: NSImage,
        temperature: Double
    ) async throws -> String {
        let imagePayload = try VisionImagePayloadEncoder.encode(image)
        let body = GeminiGenerateContentRequest(
            contents: [
                .init(
                    role: "user",
                    parts: [
                        .text(combinedPrompt(systemPrompt: systemPrompt, userPrompt: userPrompt)),
                        .inlineData(
                            mimeType: imagePayload.mimeType,
                            data: imagePayload.base64Data
                        )
                    ]
                )
            ],
            generationConfig: .init(
                temperature: temperature,
                responseMimeType: "application/json"
            )
        )
        return try await performGenerateContentRequest(body)
    }

    private func performGenerateContentRequest(
        _ body: GeminiGenerateContentRequest
    ) async throws -> String {
        var urlRequest = URLRequest(url: try resolvedEndpoint())
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await urlSession.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranslationProviderError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
            }

            let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
            let text = decoded.candidates
                .first?
                .content
                .parts
                .compactMap(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cleanedText = stripMarkdownFences(from: text)

            guard !cleanedText.isEmpty else {
                throw TranslationProviderError.invalidResponse
            }

            return cleanedText
        } catch let error as TranslationProviderError {
            throw error
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        } catch {
            throw TranslationProviderError.providerMessage("\(displayName) 请求失败：\(error.localizedDescription)")
        }
    }

    private func resolvedEndpoint() throws -> URL {
        let baseURL = endpoint ?? Self.defaultEndpoint(for: model)
        let resolvedURL = normalizedGenerateContentEndpoint(baseURL, model: model)

        guard var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false) else {
            throw TranslationProviderError.providerMessage("\(displayName) endpoint 无法解析。")
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "key" }
        queryItems.append(URLQueryItem(name: "key", value: apiKey))
        components.queryItems = queryItems

        guard let finalURL = components.url else {
            throw TranslationProviderError.providerMessage("\(displayName) endpoint 无法生成。")
        }

        return finalURL
    }

    private func normalizedGenerateContentEndpoint(
        _ endpoint: URL,
        model: String
    ) -> URL {
        let absolute = endpoint.absoluteString
        if absolute.contains("/openai/chat/completions") {
            return Self.defaultEndpoint(for: model)
        }

        if absolute.contains(":generateContent") {
            let pattern = #"/models/[^/?:]+:generateContent"#
            if let range = absolute.range(of: pattern, options: .regularExpression) {
                let replaced = absolute.replacingCharacters(in: range, with: "/models/\(model):generateContent")
                return URL(string: replaced) ?? Self.defaultEndpoint(for: model)
            }
            return endpoint
        }

        let trimmed = absolute.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("v1beta/models") || trimmed.hasSuffix("v1/models") {
            return URL(string: absolute + "/\(model):generateContent") ?? Self.defaultEndpoint(for: model)
        }

        if trimmed.hasSuffix("v1beta") || trimmed.hasSuffix("v1") {
            return URL(string: absolute + "/models/\(model):generateContent") ?? Self.defaultEndpoint(for: model)
        }

        return Self.defaultEndpoint(for: model)
    }

    private static func defaultEndpoint(for model: String) -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    private func combinedPrompt(
        systemPrompt: String,
        userPrompt: String
    ) -> String {
        """
        \(systemPrompt)

        \(userPrompt)
        """
    }

    private func stripMarkdownFences(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed.replacingOccurrences(
                of: #"^```(?:json)?\s*"#,
                with: "",
                options: .regularExpression
            )
            trimmed = trimmed.replacingOccurrences(
                of: #"\s*```$"#,
                with: "",
                options: .regularExpression
            )
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> TranslationProviderError {
        let message = (try? JSONDecoder().decode(GeminiErrorResponse.self, from: data).error.message) ??
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

private struct GeminiGenerateContentRequest: Encodable {
    var contents: [GeminiContent]
    var generationConfig: GeminiGenerationConfig?
}

private struct GeminiContent: Encodable {
    var role: String
    var parts: [GeminiPart]
}

private struct GeminiGenerationConfig: Encodable {
    var temperature: Double
    var responseMimeType: String?
}

private struct GeminiPart: Encodable {
    var text: String?
    var inlineData: GeminiInlineData?

    static func text(_ text: String) -> Self {
        .init(text: text, inlineData: nil)
    }

    static func inlineData(mimeType: String, data: String) -> Self {
        .init(
            text: nil,
            inlineData: .init(mimeType: mimeType, data: data)
        )
    }
}

private struct GeminiInlineData: Encodable {
    var mimeType: String
    var data: String
}

private struct GeminiGenerateContentResponse: Decodable {
    var candidates: [GeminiCandidate]
}

private struct GeminiCandidate: Decodable {
    var content: GeminiResponseContent
}

private struct GeminiResponseContent: Decodable {
    var parts: [GeminiResponsePart]
}

private struct GeminiResponsePart: Decodable {
    var text: String?
}

private struct GeminiErrorResponse: Decodable {
    struct ProviderError: Decodable {
        var message: String
    }

    var error: ProviderError
}
