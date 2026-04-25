import Foundation

struct GoogleTranslateProvider: TranslationProvider {
    let id: TranslationProviderID = .google
    let displayName = "Google"

    private let endpoint: URL
    private let apiKey: String
    private let timeout: TimeInterval
    private let urlSession: URLSession

    init(
        endpoint: URL,
        apiKey: String,
        timeout: TimeInterval = 30,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.timeout = timeout
        self.urlSession = urlSession
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let url = components?.url else {
            throw TranslationProviderError.invalidEndpoint
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(GoogleTranslateRequest(
            q: request.text,
            source: normalizedSourceLanguage(request.sourceLanguage),
            target: normalizedLanguage(request.targetLanguage),
            format: "text"
        ))

        do {
            let (data, response) = try await urlSession.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranslationProviderError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
            }

            let decoded = try JSONDecoder().decode(GoogleTranslateResponse.self, from: data)
            guard let translation = decoded.data.translations.first,
                  !translation.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslationProviderError.invalidResponse
            }

            return TranslationResponse(
                translatedText: translation.translatedText,
                providerID: id,
                detectedSourceLanguage: translation.detectedSourceLanguage ?? request.sourceLanguage
            )
        } catch let error as TranslationProviderError {
            throw error
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        } catch {
            throw TranslationProviderError.providerMessage("Google 翻译请求失败：\(error.localizedDescription)")
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> TranslationProviderError {
        let message = (try? JSONDecoder().decode(GoogleErrorResponse.self, from: data).error.message) ??
            String(data: data, encoding: .utf8) ??
            "未知错误"

        switch statusCode {
        case 401, 403:
            return .authenticationFailed("Google 认证失败，请检查 API Key 或 Cloud Translation API 是否已启用。")
        case 429:
            return .rateLimited("Google 请求过于频繁或额度不足，请稍后再试。")
        default:
            return .providerMessage("Google 请求失败（HTTP \(statusCode)）：\(message)")
        }
    }

    private func mapURLError(_ error: URLError) -> TranslationProviderError {
        switch error.code {
        case .timedOut:
            return .timeout("Google 翻译请求超时，请稍后再试。")
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .network("网络连接失败，无法访问 Google 翻译。")
        default:
            return .providerMessage("Google 网络错误：\(error.localizedDescription)")
        }
    }

    private func normalizedSourceLanguage(_ language: String?) -> String? {
        guard let language,
              !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return normalizedLanguage(language)
    }

    private func normalizedLanguage(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chinese", "中文", "简体中文", "zh", "zh-cn", "zh-hans":
            return "zh-CN"
        case "traditional chinese", "繁体中文", "zh-tw", "zh-hant":
            return "zh-TW"
        case "english", "英语", "en", "en-us", "en-gb":
            return "en"
        case "japanese", "日语", "ja", "jp":
            return "ja"
        case "korean", "韩语", "ko", "kr":
            return "ko"
        case "french", "法语", "fr":
            return "fr"
        case "german", "德语", "de":
            return "de"
        case "spanish", "西班牙语", "es":
            return "es"
        case "russian", "俄语", "ru":
            return "ru"
        default:
            return value
        }
    }
}

private struct GoogleTranslateRequest: Encodable {
    var q: String
    var source: String?
    var target: String
    var format: String
}

private struct GoogleTranslateResponse: Decodable {
    struct DataContainer: Decodable {
        var translations: [Translation]
    }

    struct Translation: Decodable {
        var translatedText: String
        var detectedSourceLanguage: String?
    }

    var data: DataContainer
}

private struct GoogleErrorResponse: Decodable {
    struct ErrorBody: Decodable {
        var message: String
    }

    var error: ErrorBody
}
