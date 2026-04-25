import Foundation

struct VolcengineTranslateProvider: TranslationProvider {
    let id: TranslationProviderID = .volcengine
    let displayName = "火山翻译"

    private let endpoint: URL
    private let accessKeyID: String
    private let secretAccessKey: String
    private let region: String
    private let timeout: TimeInterval
    private let urlSession: URLSession

    init(
        endpoint: URL,
        accessKeyID: String,
        secretAccessKey: String,
        region: String = "cn-north-1",
        timeout: TimeInterval = 30,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.region = region
        self.timeout = timeout
        self.urlSession = urlSession
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        guard let host = endpoint.host else {
            throw TranslationProviderError.invalidEndpoint
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "Action", value: "TranslateText"),
            URLQueryItem(name: "Version", value: "2020-06-01")
        ]
        guard let url = components?.url else {
            throw TranslationProviderError.invalidEndpoint
        }

        let payload = VolcengineTranslateRequest(
            sourceLanguage: normalizedSourceLanguage(request.sourceLanguage),
            targetLanguage: normalizedLanguage(request.targetLanguage),
            textList: [request.text]
        )
        let payloadData = try JSONEncoder.volcengine.encode(payload)
        let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"
        let payloadHash = SigningUtilities.sha256Hex(payloadString)
        let signingDate = Date()
        let xDate = xDateString(signingDate)
        let shortDate = shortDateString(signingDate)
        let authorization = authorizationHeader(
            host: host,
            xDate: xDate,
            shortDate: shortDate,
            canonicalQueryString: "Action=TranslateText&Version=2020-06-01",
            payloadHash: payloadHash
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue(host, forHTTPHeaderField: "Host")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(xDate, forHTTPHeaderField: "X-Date")
        urlRequest.setValue(payloadHash, forHTTPHeaderField: "X-Content-Sha256")
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

            let decoded = try JSONDecoder.volcengine.decode(VolcengineTranslateResponse.self, from: data)
            if let error = decoded.responseMetadata?.error {
                throw mapVolcengineError(code: error.code, message: error.message)
            }

            guard let translatedText = decoded.translationList?.first?.translation.trimmingCharacters(in: .whitespacesAndNewlines),
                  !translatedText.isEmpty else {
                throw TranslationProviderError.invalidResponse
            }

            return TranslationResponse(
                translatedText: translatedText,
                providerID: id,
                detectedSourceLanguage: decoded.translationList?.first?.detectedSourceLanguage ?? request.sourceLanguage
            )
        } catch let error as TranslationProviderError {
            throw error
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        } catch {
            throw TranslationProviderError.providerMessage("火山翻译请求失败：\(error.localizedDescription)")
        }
    }

    private func authorizationHeader(
        host: String,
        xDate: String,
        shortDate: String,
        canonicalQueryString: String,
        payloadHash: String
    ) -> String {
        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonicalHeaders = [
            "content-type:application/json",
            "host:\(host)",
            "x-content-sha256:\(payloadHash)",
            "x-date:\(xDate)"
        ].joined(separator: "\n") + "\n"

        let canonicalRequest = [
            "POST",
            "/",
            canonicalQueryString,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(shortDate)/\(region)/translate/request"
        let stringToSign = [
            "HMAC-SHA256",
            xDate,
            credentialScope,
            SigningUtilities.sha256Hex(canonicalRequest)
        ].joined(separator: "\n")

        let dateKey = SigningUtilities.hmacSHA256(key: Data(secretAccessKey.utf8), message: shortDate)
        let regionKey = SigningUtilities.hmacSHA256(key: dateKey, message: region)
        let serviceKey = SigningUtilities.hmacSHA256(key: regionKey, message: "translate")
        let signingKey = SigningUtilities.hmacSHA256(key: serviceKey, message: "request")
        let signature = SigningUtilities.hmacSHA256Hex(key: signingKey, message: stringToSign)

        return "HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> TranslationProviderError {
        let message = String(data: data, encoding: .utf8) ?? "未知错误"
        switch statusCode {
        case 401, 403:
            return .authenticationFailed("火山翻译认证失败，请检查 Access Key / Secret Key。")
        case 429:
            return .rateLimited("火山翻译请求过于频繁或额度不足，请稍后再试。")
        default:
            return .providerMessage("火山翻译请求失败（HTTP \(statusCode)）：\(message)")
        }
    }

    private func mapVolcengineError(code: String, message: String) -> TranslationProviderError {
        if code.contains("Auth") || code.contains("Signature") || code.contains("InvalidAccessKey") {
            return .authenticationFailed("火山翻译认证失败：\(message)")
        }
        if code.contains("Limit") || code.contains("TooMany") || code.contains("Quota") {
            return .rateLimited("火山翻译请求受限：\(message)")
        }
        return .providerMessage("火山翻译错误 \(code)：\(message)")
    }

    private func mapURLError(_ error: URLError) -> TranslationProviderError {
        switch error.code {
        case .timedOut:
            return .timeout("火山翻译请求超时，请稍后再试。")
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .network("网络连接失败，无法访问火山翻译。")
        default:
            return .providerMessage("火山翻译网络错误：\(error.localizedDescription)")
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

    private func xDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private func shortDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

private struct VolcengineTranslateRequest: Encodable {
    var sourceLanguage: String
    var targetLanguage: String
    var textList: [String]
}

private struct VolcengineTranslateResponse: Decodable {
    struct Translation: Decodable {
        var translation: String
        var detectedSourceLanguage: String?
    }

    struct Metadata: Decodable {
        struct ErrorBody: Decodable {
            var code: String
            var message: String
        }

        var error: ErrorBody?
    }

    var translationList: [Translation]?
    var responseMetadata: Metadata?
}

private extension JSONEncoder {
    static var volcengine: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { keys in
            let key = keys.last!.stringValue
            switch key {
            case "sourceLanguage":
                return VolcengineCodingKey("SourceLanguage")
            case "targetLanguage":
                return VolcengineCodingKey("TargetLanguage")
            case "textList":
                return VolcengineCodingKey("TextList")
            default:
                return VolcengineCodingKey(key)
            }
        }
        return encoder
    }
}

private extension JSONDecoder {
    static var volcengine: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let key = keys.last!.stringValue
            switch key {
            case "TranslationList":
                return VolcengineCodingKey("translationList")
            case "Translation":
                return VolcengineCodingKey("translation")
            case "DetectedSourceLanguage":
                return VolcengineCodingKey("detectedSourceLanguage")
            case "ResponseMetadata":
                return VolcengineCodingKey("responseMetadata")
            case "Error":
                return VolcengineCodingKey("error")
            case "Code":
                return VolcengineCodingKey("code")
            case "Message":
                return VolcengineCodingKey("message")
            default:
                return VolcengineCodingKey(key)
            }
        }
        return decoder
    }
}

private struct VolcengineCodingKey: CodingKey {
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
