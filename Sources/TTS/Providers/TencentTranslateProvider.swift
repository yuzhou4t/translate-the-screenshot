import Foundation

struct TencentTranslateProvider: TranslationProvider {
    let id: TranslationProviderID = .tencent
    let displayName = "腾讯翻译"

    private let endpoint: URL
    private let secretID: String
    private let secretKey: String
    private let region: String
    private let timeout: TimeInterval
    private let urlSession: URLSession

    init(
        endpoint: URL,
        secretID: String,
        secretKey: String,
        region: String = "ap-guangzhou",
        timeout: TimeInterval = 30,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.secretID = secretID
        self.secretKey = secretKey
        self.region = region
        self.timeout = timeout
        self.urlSession = urlSession
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        guard let host = endpoint.host else {
            throw TranslationProviderError.invalidEndpoint
        }

        let payload = TencentTranslateRequest(
            sourceText: request.text,
            source: normalizedSourceLanguage(request.sourceLanguage),
            target: normalizedLanguage(request.targetLanguage),
            projectID: 0
        )
        let payloadData = try JSONEncoder.tencent.encode(payload)
        let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"
        let timestamp = Int(Date().timeIntervalSince1970)
        let authorization = authorizationHeader(
            host: host,
            timestamp: timestamp,
            payload: payloadString
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(host, forHTTPHeaderField: "Host")
        urlRequest.setValue("TextTranslate", forHTTPHeaderField: "X-TC-Action")
        urlRequest.setValue("2018-03-21", forHTTPHeaderField: "X-TC-Version")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        urlRequest.setValue(region, forHTTPHeaderField: "X-TC-Region")
        urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = payloadData

        do {
            let (data, response) = try await urlSession.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranslationProviderError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
            }

            let decoded = try JSONDecoder.tencent.decode(TencentTranslateResponse.self, from: data)
            if let error = decoded.response.error {
                throw mapTencentError(code: error.code, message: error.message)
            }

            guard let translatedText = decoded.response.targetText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !translatedText.isEmpty else {
                throw TranslationProviderError.invalidResponse
            }

            return TranslationResponse(
                translatedText: translatedText,
                providerID: id,
                detectedSourceLanguage: decoded.response.source
            )
        } catch let error as TranslationProviderError {
            throw error
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        } catch {
            throw TranslationProviderError.providerMessage("腾讯翻译请求失败：\(error.localizedDescription)")
        }
    }

    private func authorizationHeader(host: String, timestamp: Int, payload: String) -> String {
        let contentType = "application/json; charset=utf-8"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\n"
        let signedHeaders = "content-type;host"
        let hashedPayload = SigningUtilities.sha256Hex(payload)
        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            hashedPayload
        ].joined(separator: "\n")

        let date = utcDateString(timestamp: timestamp)
        let credentialScope = "\(date)/tmt/tc3_request"
        let stringToSign = [
            "TC3-HMAC-SHA256",
            String(timestamp),
            credentialScope,
            SigningUtilities.sha256Hex(canonicalRequest)
        ].joined(separator: "\n")

        let secretDate = SigningUtilities.hmacSHA256(key: Data("TC3\(secretKey)".utf8), message: date)
        let secretService = SigningUtilities.hmacSHA256(key: secretDate, message: "tmt")
        let secretSigning = SigningUtilities.hmacSHA256(key: secretService, message: "tc3_request")
        let signature = SigningUtilities.hmacSHA256Hex(key: secretSigning, message: stringToSign)

        return "TC3-HMAC-SHA256 Credential=\(secretID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> TranslationProviderError {
        let message = String(data: data, encoding: .utf8) ?? "未知错误"
        switch statusCode {
        case 401, 403:
            return .authenticationFailed("腾讯翻译认证失败，请检查 SecretId / SecretKey。")
        case 429:
            return .rateLimited("腾讯翻译请求过于频繁或额度不足，请稍后再试。")
        default:
            return .providerMessage("腾讯翻译请求失败（HTTP \(statusCode)）：\(message)")
        }
    }

    private func mapTencentError(code: String, message: String) -> TranslationProviderError {
        if code.contains("AuthFailure") || code.contains("Unauthorized") {
            return .authenticationFailed("腾讯翻译认证失败：\(message)")
        }
        if code.contains("LimitExceeded") || code.contains("TooManyRequests") || code.contains("RequestLimitExceeded") {
            return .rateLimited("腾讯翻译请求受限：\(message)")
        }
        return .providerMessage("腾讯翻译错误 \(code)：\(message)")
    }

    private func mapURLError(_ error: URLError) -> TranslationProviderError {
        switch error.code {
        case .timedOut:
            return .timeout("腾讯翻译请求超时，请稍后再试。")
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .network("网络连接失败，无法访问腾讯翻译。")
        default:
            return .providerMessage("腾讯翻译网络错误：\(error.localizedDescription)")
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

    private func utcDateString(timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}

private struct TencentTranslateRequest: Encodable {
    var sourceText: String
    var source: String
    var target: String
    var projectID: Int
}

private struct TencentTranslateResponse: Decodable {
    struct ResponseBody: Decodable {
        struct ErrorBody: Decodable {
            var code: String
            var message: String
        }

        var source: String?
        var target: String?
        var targetText: String?
        var error: ErrorBody?
        var requestID: String?
    }

    var response: ResponseBody
}

private extension JSONEncoder {
    static var tencent: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { keys in
            let key = keys.last!.stringValue
            switch key {
            case "sourceText":
                return AnyCodingKey("SourceText")
            case "source":
                return AnyCodingKey("Source")
            case "target":
                return AnyCodingKey("Target")
            case "projectID":
                return AnyCodingKey("ProjectId")
            default:
                return AnyCodingKey(key)
            }
        }
        return encoder
    }
}

private extension JSONDecoder {
    static var tencent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let key = keys.last!.stringValue
            switch key {
            case "Response":
                return AnyCodingKey("response")
            case "Source":
                return AnyCodingKey("source")
            case "Target":
                return AnyCodingKey("target")
            case "TargetText":
                return AnyCodingKey("targetText")
            case "Error":
                return AnyCodingKey("error")
            case "Code":
                return AnyCodingKey("code")
            case "Message":
                return AnyCodingKey("message")
            case "RequestId":
                return AnyCodingKey("requestID")
            default:
                return AnyCodingKey(key)
            }
        }
        return decoder
    }
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
