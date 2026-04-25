import Foundation

struct BingTranslateProvider: TranslationProvider {
    let id: TranslationProviderID = .bing
    let displayName = "Bing"

    private let endpoint: URL
    private let apiKey: String
    private let region: String?
    private let timeout: TimeInterval
    private let urlSession: URLSession

    init(
        endpoint: URL,
        apiKey: String,
        region: String?,
        timeout: TimeInterval = 30,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.region = region?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timeout = timeout
        self.urlSession = urlSession
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "api-version", value: "3.0"))
        queryItems.append(URLQueryItem(name: "to", value: normalizedTargetLanguage(request.targetLanguage)))

        if let sourceLanguage = normalizedSourceLanguage(request.sourceLanguage) {
            queryItems.append(URLQueryItem(name: "from", value: sourceLanguage))
        }

        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw TranslationProviderError.invalidEndpoint
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        if let region, !region.isEmpty {
            urlRequest.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        }
        urlRequest.httpBody = try JSONEncoder().encode([BingTranslateRequest(text: request.text)])

        do {
            let (data, response) = try await urlSession.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranslationProviderError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
            }

            let decoded = try JSONDecoder().decode([BingTranslateResponse].self, from: data)
            guard let item = decoded.first,
                  let translation = item.translations.first,
                  !translation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslationProviderError.invalidResponse
            }

            return TranslationResponse(
                translatedText: translation.text,
                providerID: id,
                detectedSourceLanguage: item.detectedLanguage?.language ?? request.sourceLanguage
            )
        } catch let error as TranslationProviderError {
            throw error
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        } catch {
            throw TranslationProviderError.providerMessage("Bing 翻译请求失败：\(error.localizedDescription)")
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> TranslationProviderError {
        let message = (try? JSONDecoder().decode(BingErrorResponse.self, from: data).error.message) ??
            String(data: data, encoding: .utf8) ??
            "未知错误"

        switch statusCode {
        case 401, 403:
            return .authenticationFailed("Bing 翻译认证失败，请检查 Azure Translator Key 和区域。")
        case 429:
            return .rateLimited("Bing 翻译请求过于频繁或额度不足，请稍后再试。")
        default:
            return .providerMessage("Bing 翻译请求失败（HTTP \(statusCode)）：\(message)")
        }
    }

    private func mapURLError(_ error: URLError) -> TranslationProviderError {
        switch error.code {
        case .timedOut:
            return .timeout("Bing 翻译请求超时，请稍后再试。")
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .network("网络连接失败，无法访问 Bing 翻译。")
        default:
            return .providerMessage("Bing 翻译网络错误：\(error.localizedDescription)")
        }
    }

    private func normalizedSourceLanguage(_ language: String?) -> String? {
        guard let language,
              !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return normalizedTargetLanguage(language)
    }

    private func normalizedTargetLanguage(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chinese", "中文", "简体中文", "zh", "zh-cn", "zh-hans":
            return "zh-Hans"
        case "traditional chinese", "繁体中文", "zh-tw", "zh-hant":
            return "zh-Hant"
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

private struct BingTranslateRequest: Encodable {
    var text: String

    private enum CodingKeys: String, CodingKey {
        case text = "Text"
    }
}

private struct BingTranslateResponse: Decodable {
    struct DetectedLanguage: Decodable {
        var language: String
    }

    struct Translation: Decodable {
        var text: String
        var to: String
    }

    var detectedLanguage: DetectedLanguage?
    var translations: [Translation]
}

private struct BingErrorResponse: Decodable {
    struct ErrorBody: Decodable {
        var message: String
    }

    var error: ErrorBody
}
