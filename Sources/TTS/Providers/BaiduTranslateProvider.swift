import Foundation

struct BaiduTranslateProvider: TranslationProvider {
    let id: TranslationProviderID = .baidu
    let displayName = "百度翻译"

    private let endpoint: URL
    private let appID: String
    private let secretKey: String
    private let timeout: TimeInterval
    private let urlSession: URLSession

    init(
        endpoint: URL,
        appID: String,
        secretKey: String,
        timeout: TimeInterval = 30,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.appID = appID
        self.secretKey = secretKey
        self.timeout = timeout
        self.urlSession = urlSession
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        let salt = String(Int(Date().timeIntervalSince1970 * 1000))
        let sourceLanguage = normalizedSourceLanguage(request.sourceLanguage)
        let targetLanguage = normalizedLanguage(request.targetLanguage)
        let sign = SigningUtilities.md5Hex(appID + request.text + salt + secretKey)

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: request.text),
            URLQueryItem(name: "from", value: sourceLanguage),
            URLQueryItem(name: "to", value: targetLanguage),
            URLQueryItem(name: "appid", value: appID),
            URLQueryItem(name: "salt", value: salt),
            URLQueryItem(name: "sign", value: sign)
        ]

        guard let url = components?.url else {
            throw TranslationProviderError.invalidEndpoint
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = timeout

        do {
            let (data, response) = try await urlSession.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranslationProviderError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
            }

            let decoded = try JSONDecoder().decode(BaiduTranslateResponse.self, from: data)
            if let errorCode = decoded.errorCode {
                throw mapBaiduError(code: errorCode, message: decoded.errorMessage ?? "未知错误")
            }

            let translatedText = decoded.transResult?
                .map(\.dst)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let translatedText, !translatedText.isEmpty else {
                throw TranslationProviderError.invalidResponse
            }

            return TranslationResponse(
                translatedText: translatedText,
                providerID: id,
                detectedSourceLanguage: decoded.from
            )
        } catch let error as TranslationProviderError {
            throw error
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        } catch {
            throw TranslationProviderError.providerMessage("百度翻译请求失败：\(error.localizedDescription)")
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> TranslationProviderError {
        let message = String(data: data, encoding: .utf8) ?? "未知错误"
        switch statusCode {
        case 401, 403:
            return .authenticationFailed("百度翻译认证失败，请检查 App ID / Secret Key。")
        case 429:
            return .rateLimited("百度翻译请求过于频繁或额度不足，请稍后再试。")
        default:
            return .providerMessage("百度翻译请求失败（HTTP \(statusCode)）：\(message)")
        }
    }

    private func mapBaiduError(code: String, message: String) -> TranslationProviderError {
        switch code {
        case "52003", "54001":
            return .authenticationFailed("百度翻译认证失败：\(message)")
        case "54003", "54005":
            return .rateLimited("百度翻译请求受限：\(message)")
        default:
            return .providerMessage("百度翻译错误 \(code)：\(message)")
        }
    }

    private func mapURLError(_ error: URLError) -> TranslationProviderError {
        switch error.code {
        case .timedOut:
            return .timeout("百度翻译请求超时，请稍后再试。")
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .network("网络连接失败，无法访问百度翻译。")
        default:
            return .providerMessage("百度翻译网络错误：\(error.localizedDescription)")
        }
    }

    private func normalizedSourceLanguage(_ language: String?) -> String {
        guard let language,
              !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "auto"
        }

        return normalizedLanguage(language)
    }

    private func normalizedLanguage(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chinese", "中文", "简体中文", "zh", "zh-cn", "zh-hans":
            return "zh"
        case "traditional chinese", "繁体中文", "zh-tw", "zh-hant":
            return "cht"
        case "english", "英语", "en", "en-us", "en-gb":
            return "en"
        case "japanese", "日语", "ja", "jp":
            return "jp"
        case "korean", "韩语", "ko", "kr":
            return "kor"
        case "french", "法语", "fr":
            return "fra"
        case "german", "德语", "de":
            return "de"
        case "spanish", "西班牙语", "es":
            return "spa"
        case "russian", "俄语", "ru":
            return "ru"
        default:
            return value
        }
    }
}

private struct BaiduTranslateResponse: Decodable {
    struct Translation: Decodable {
        var src: String
        var dst: String
    }

    var from: String?
    var to: String?
    var transResult: [Translation]?
    var errorCode: String?
    var errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case from
        case to
        case transResult = "trans_result"
        case errorCode = "error_code"
        case errorMessage = "error_msg"
    }
}
