import Foundation

struct DeepLProvider: TranslationProvider {
    let id: TranslationProviderID = .deepL
    let displayName = "DeepL"

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
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = DeepLTranslateRequest(
            text: [request.text],
            sourceLang: normalizedSourceLanguage(request.sourceLanguage),
            targetLang: normalizedTargetLanguage(request.targetLanguage)
        )
        urlRequest.httpBody = try JSONEncoder.deepLSnakeCase.encode(body)

        do {
            let (data, response) = try await urlSession.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranslationProviderError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
            }

            let decoded = try JSONDecoder().decode(DeepLTranslateResponse.self, from: data)
            guard let translation = decoded.translations.first,
                  !translation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslationProviderError.invalidResponse
            }

            return TranslationResponse(
                translatedText: translation.text,
                providerID: id,
                detectedSourceLanguage: translation.detectedSourceLanguage
            )
        } catch let error as TranslationProviderError {
            throw error
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        } catch {
            throw TranslationProviderError.providerMessage("DeepL 网络请求失败：\(error.localizedDescription)")
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> TranslationProviderError {
        let details = (try? JSONDecoder().decode(DeepLErrorResponse.self, from: data).message) ??
            String(data: data, encoding: .utf8)

        switch statusCode {
        case 401, 403:
            return .authenticationFailed("DeepL 认证失败，请检查 API Key。")
        case 429:
            return .rateLimited("DeepL 请求过于频繁，请稍后再试。")
        case 456:
            return .providerMessage("DeepL 额度已用尽。")
        case 500, 504, 529:
            return .providerMessage("DeepL 服务暂时不可用，请稍后再试。")
        default:
            if let details, !details.isEmpty {
                return .providerMessage("DeepL 请求失败（HTTP \(statusCode)）：\(details)")
            }
            return .providerMessage("DeepL 请求失败（HTTP \(statusCode)）。")
        }
    }

    private func mapURLError(_ error: URLError) -> TranslationProviderError {
        switch error.code {
        case .timedOut:
            return .timeout("DeepL 请求超时，请稍后再试。")
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .network("网络连接失败，无法访问 DeepL。")
        default:
            return .providerMessage("DeepL 网络错误：\(error.localizedDescription)")
        }
    }

    private func normalizedSourceLanguage(_ language: String?) -> String? {
        guard let language,
              !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return normalizeLanguage(language, isTarget: false)
    }

    private func normalizedTargetLanguage(_ language: String) -> String {
        normalizeLanguage(language, isTarget: true)
    }

    private func normalizeLanguage(_ language: String, isTarget: Bool) -> String {
        switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chinese", "中文", "简体中文", "zh", "zh-cn", "zh-hans":
            return "ZH"
        case "traditional chinese", "繁体中文", "zh-tw", "zh-hant":
            return "ZH"
        case "english", "英语", "en":
            return isTarget ? "EN-US" : "EN"
        case "en-us":
            return isTarget ? "EN-US" : "EN"
        case "en-gb":
            return isTarget ? "EN-GB" : "EN"
        case "japanese", "日语", "ja", "jp":
            return "JA"
        case "korean", "韩语", "ko", "kr":
            return "KO"
        case "french", "法语", "fr":
            return "FR"
        case "german", "德语", "de":
            return "DE"
        case "spanish", "西班牙语", "es":
            return "ES"
        case "russian", "俄语", "ru":
            return "RU"
        default:
            return language.uppercased()
        }
    }
}

private struct DeepLTranslateRequest: Encodable {
    var text: [String]
    var sourceLang: String?
    var targetLang: String
}

private struct DeepLTranslateResponse: Decodable {
    struct Translation: Decodable {
        var detectedSourceLanguage: String?
        var text: String

        private enum CodingKeys: String, CodingKey {
            case detectedSourceLanguage = "detected_source_language"
            case text
        }
    }

    var translations: [Translation]
}

private struct DeepLErrorResponse: Decodable {
    var message: String?
}

private extension JSONEncoder {
    static var deepLSnakeCase: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}
