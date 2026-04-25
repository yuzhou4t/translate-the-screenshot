import Foundation

struct MyMemoryProvider: TranslationProvider {
    let id: TranslationProviderID = .myMemory
    let displayName = "MyMemory 免费测试"

    private let endpoint = URL(string: "https://api.mymemory.translated.net/get")!
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        guard Data(request.text.utf8).count <= 500 else {
            throw TranslationProviderError.providerMessage("MyMemory 免费接口单次最多支持约 500 bytes 文本，请选短一点再试。")
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: request.text),
            URLQueryItem(name: "langpair", value: "\(sourceLanguageCode(from: request.sourceLanguage))|\(targetLanguageCode(from: request.targetLanguage))")
        ]

        guard let url = components?.url else {
            throw TranslationProviderError.invalidEndpoint
        }

        let (data, response) = try await urlSession.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw TranslationProviderError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(MyMemoryResponse.self, from: data)
        guard decoded.responseStatus == 200 else {
            throw TranslationProviderError.providerMessage(decoded.responseDetails ?? "MyMemory 翻译失败。")
        }

        let translatedText = decoded.responseData.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translatedText.isEmpty else {
            throw TranslationProviderError.invalidResponse
        }

        return TranslationResponse(
            translatedText: translatedText,
            providerID: id,
            detectedSourceLanguage: sourceLanguageCode(from: request.sourceLanguage)
        )
    }

    private func sourceLanguageCode(from sourceLanguage: String?) -> String {
        guard let sourceLanguage, !sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "en"
        }

        return normalizeLanguageCode(sourceLanguage)
    }

    private func targetLanguageCode(from targetLanguage: String) -> String {
        normalizeLanguageCode(targetLanguage)
    }

    private func normalizeLanguageCode(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chinese", "中文", "简体中文", "zh", "zh-cn":
            return "zh-CN"
        case "traditional chinese", "繁体中文", "zh-tw":
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

private struct MyMemoryResponse: Decodable {
    struct ResponseData: Decodable {
        var translatedText: String
    }

    var responseData: ResponseData
    var responseStatus: Int
    var responseDetails: String?
}
