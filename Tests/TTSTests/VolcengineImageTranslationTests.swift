@testable import TTS
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@_cdecl("runVolcengineImageTranslationRegressionChecks")
public func runVolcengineImageTranslationRegressionChecks() {
    checkVolcengineImagePayloadEncoderPreservesCompliantOriginalPNG()
    checkVolcengineImagePayloadEncoderReencodesDataOverFourMillionBytes()
    checkVolcengineImagePayloadEncoderScalesLongestEdgeTo4096()
    checkVolcengineImagePayloadEncoderConvertsOtherImageContainers()

    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        await checkVolcengineTranslateImageBuildsOfficialRequestAndParsesTopLevelResponse()
        await checkVolcengineTranslateImageDoesNotRetryTransientFailure()
        await checkVolcengineGetImageUsageBuildsOfficialRequestAndSumsPoints()
        await checkVolcengineGetImageUsageDoesNotRetryFailure()
        semaphore.signal()
    }
    precondition(
        semaphore.wait(timeout: .now() + 15) == .success,
        "Volcengine image translation regression checks timed out"
    )
}

func checkVolcengineTranslateImageBuildsOfficialRequestAndParsesTopLevelResponse() async {
    let inputImageData = try! makeImageData(width: 12, height: 8, type: .png)
    let translatedImageData = try! makeImageData(width: 12, height: 8, type: .jpeg)
    let responseData = try! JSONSerialization.data(
        withJSONObject: [
            "Image": translatedImageData.base64EncodedString(),
            "TextBlocks": [
                [
                    "Points": [
                        ["X": 1, "Y": 2],
                        ["X": 11, "Y": 2],
                        ["X": 1, "Y": 7],
                        ["X": 11, "Y": 7]
                    ],
                    "DetectedLanguage": "en",
                    "Text": "Hello",
                    "Translation": "你好",
                    "ForeColor": [0, 0, 0, 255],
                    "BackColor": [255, 255, 255, 255]
                ]
            ],
            "ResponseMetadata": [
                "RequestId": "request-id",
                "Action": "TranslateImage",
                "Version": "2020-07-01",
                "Service": "translate",
                "Region": "cn-north-1"
            ]
        ]
    )
    let recorder = VolcengineRequestRecorder()
    VolcengineURLProtocolStub.handler = { request in
        recorder.record(request)
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, responseData)
    }
    defer {
        VolcengineURLProtocolStub.handler = nil
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VolcengineURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer {
        session.invalidateAndCancel()
    }
    let provider = VolcengineTranslateProvider(
        endpoint: URL(string: "https://translate.volcengineapi.com")!,
        accessKeyID: "test-ak",
        secretAccessKey: "test-sk",
        urlSession: session,
        now: { Date(timeIntervalSince1970: 0) }
    )

    let result = try! await provider.translateImage(
        imageData: inputImageData,
        targetLanguage: "简体中文"
    )

    precondition(result.imageData == translatedImageData)
    precondition(result.textBlocks.count == 1)
    precondition(result.textBlocks[0].detectedLanguage == "en")
    precondition(result.textBlocks[0].text == "Hello")
    precondition(result.textBlocks[0].translation == "你好")
    precondition(
        result.textBlocks[0].points == [
            VolcengineImagePoint(x: 1, y: 2),
            VolcengineImagePoint(x: 11, y: 2),
            VolcengineImagePoint(x: 1, y: 7),
            VolcengineImagePoint(x: 11, y: 7)
        ]
    )
    precondition(result.textBlocks[0].foreColor == [0, 0, 0, 255])
    precondition(result.textBlocks[0].backColor == [255, 255, 255, 255])
    precondition(result.responseMetadata?.requestID == "request-id")

    let requests = recorder.snapshot()
    precondition(
        requests.count == 1,
        "TranslateImage must perform exactly one request"
    )
    guard let request = requests.first else {
        preconditionFailure("Expected one TranslateImage request")
    }
    precondition(request.httpMethod == "POST")
    precondition(request.url?.host == "translate.volcengineapi.com")
    guard let url = request.url,
          let queryItems = URLComponents(
              url: url,
              resolvingAgainstBaseURL: false
          )?.queryItems else {
        preconditionFailure("Expected valid TranslateImage query items")
    }
    let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        }
    )
    precondition(query["Action"] == "TranslateImage")
    precondition(query["Version"] == "2020-07-01")
    precondition(
        request.value(forHTTPHeaderField: "Content-Type") == "application/json"
    )
    precondition(
        request.value(forHTTPHeaderField: "X-Date") == "19700101T000000Z"
    )

    guard let requestBody = requestBodyData(from: request),
          let requestObject = try! JSONSerialization.jsonObject(
              with: requestBody
          ) as? [String: Any] else {
        preconditionFailure("Expected official TranslateImage JSON body")
    }
    precondition(
        Set(requestObject.keys) == Set(["Image", "TargetLanguage"])
    )
    precondition(requestObject["TargetLanguage"] as? String == "zh")
    precondition(
        requestObject["Image"] as? String == inputImageData.base64EncodedString()
    )
    precondition(
        request.value(forHTTPHeaderField: "X-Content-Sha256")
            == SigningUtilities.sha256Hex(requestBody)
    )
    guard let authorization = request.value(
        forHTTPHeaderField: "Authorization"
    ) else {
        preconditionFailure("Expected TranslateImage authorization header")
    }
    precondition(
        authorization.contains(
            "Credential=test-ak/19700101/cn-north-1/translate/request"
        )
    )
    precondition(
        authorization.contains(
            "SignedHeaders=content-type;host;x-content-sha256;x-date"
        )
    )
}

func checkVolcengineTranslateImageDoesNotRetryTransientFailure() async {
    let inputImageData = try! makeImageData(width: 12, height: 8, type: .png)
    let recorder = VolcengineRequestRecorder()
    VolcengineURLProtocolStub.handler = { request in
        recorder.record(request)
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 500,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (response, Data("transient failure".utf8))
    }
    defer {
        VolcengineURLProtocolStub.handler = nil
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VolcengineURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer {
        session.invalidateAndCancel()
    }
    let provider = VolcengineTranslateProvider(
        endpoint: URL(string: "https://translate.volcengineapi.com")!,
        accessKeyID: "test-ak",
        secretAccessKey: "test-sk",
        urlSession: session
    )

    do {
        _ = try await provider.translateImage(
            imageData: inputImageData,
            targetLanguage: "zh"
        )
        preconditionFailure("Expected transient TranslateImage failure")
    } catch {
        precondition(
            recorder.snapshot().count == 1,
            "TranslateImage must not retry failed requests automatically"
        )
    }
}

func checkVolcengineGetImageUsageBuildsOfficialRequestAndSumsPoints() async {
    let responseData = try! JSONSerialization.data(
        withJSONObject: [
            "ResponseMetadata": [
                "RequestId": "usage-request-id",
                "Action": "GetUsage",
                "Version": "2025-03-01",
                "Service": "translate",
                "Region": "cn-beijing"
            ],
            "Result": [
                "Points": [
                    ["Timestamp": 1_744_009_200, "Value": 27],
                    ["Timestamp": 1_744_012_800, "Value": 9],
                    ["Timestamp": 1_744_016_400, "Value": 27],
                    ["Timestamp": 1_744_020_000, "Value": -5]
                ]
            ]
        ]
    )
    let recorder = VolcengineRequestRecorder()
    VolcengineURLProtocolStub.handler = { request in
        recorder.record(request)
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, responseData)
    }
    defer {
        VolcengineURLProtocolStub.handler = nil
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VolcengineURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer {
        session.invalidateAndCancel()
    }
    let provider = VolcengineTranslateProvider(
        endpoint: URL(string: "https://translate.volcengineapi.com")!,
        accessKeyID: "test-ak",
        secretAccessKey: "test-sk",
        region: "cn-north-1",
        urlSession: session,
        now: { Date(timeIntervalSince1970: 0) }
    )

    let total = try! await provider.getImageUsage(
        from: 2025_03_21,
        to: 2025_03_28
    )

    precondition(total == 63)
    let requests = recorder.snapshot()
    precondition(
        requests.count == 1,
        "GetUsage must perform exactly one request"
    )
    guard let request = requests.first else {
        preconditionFailure("Expected one GetUsage request")
    }
    precondition(request.httpMethod == "POST")
    precondition(request.url?.host == "translate.volcengineapi.com")
    guard let url = request.url,
          let queryItems = URLComponents(
              url: url,
              resolvingAgainstBaseURL: false
          )?.queryItems else {
        preconditionFailure("Expected valid GetUsage query items")
    }
    let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        }
    )
    precondition(query["Action"] == "GetUsage")
    precondition(query["Version"] == "2025-03-01")
    precondition(
        request.value(forHTTPHeaderField: "Content-Type")
            == "application/json; charset=UTF-8"
    )
    precondition(
        request.value(forHTTPHeaderField: "X-Date") == "19700101T000000Z"
    )

    guard let requestBody = requestBodyData(from: request),
          let requestObject = try! JSONSerialization.jsonObject(
              with: requestBody
          ) as? [String: Any] else {
        preconditionFailure("Expected official GetUsage JSON body")
    }
    precondition(Set(requestObject.keys) == Set(["Service", "From", "To"]))
    precondition(requestObject["Service"] as? String == "image")
    precondition(requestObject["From"] as? Int == 2025_03_21)
    precondition(requestObject["To"] as? Int == 2025_03_28)
    precondition(
        request.value(forHTTPHeaderField: "X-Content-Sha256")
            == SigningUtilities.sha256Hex(requestBody)
    )
    guard let authorization = request.value(
        forHTTPHeaderField: "Authorization"
    ) else {
        preconditionFailure("Expected GetUsage authorization header")
    }
    precondition(
        authorization.contains(
            "Credential=test-ak/19700101/cn-beijing/translate/request"
        )
    )
    precondition(
        authorization.contains(
            "SignedHeaders=host;x-content-sha256;x-date"
        )
    )
}

func checkVolcengineGetImageUsageDoesNotRetryFailure() async {
    let recorder = VolcengineRequestRecorder()
    VolcengineURLProtocolStub.handler = { request in
        recorder.record(request)
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 500,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (response, Data("transient failure".utf8))
    }
    defer {
        VolcengineURLProtocolStub.handler = nil
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VolcengineURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer {
        session.invalidateAndCancel()
    }
    let provider = VolcengineTranslateProvider(
        endpoint: URL(string: "https://translate.volcengineapi.com")!,
        accessKeyID: "test-ak",
        secretAccessKey: "test-sk",
        urlSession: session
    )

    do {
        _ = try await provider.getImageUsage(
            from: 2025_03_21,
            to: 2025_03_28
        )
        preconditionFailure("Expected GetUsage failure")
    } catch {
        precondition(
            recorder.snapshot().count == 1,
            "GetUsage must not retry failed requests automatically"
        )
    }
}

func checkVolcengineImagePayloadEncoderPreservesCompliantOriginalPNG() {
    let originalData = try! makeImageData(width: 64, height: 32, type: .png)
    let payload = try! VolcengineImagePayloadEncoder.encode(
        originalData: originalData
    )

    precondition(payload.data == originalData)
    precondition(payload.format == .png)
    precondition(payload.pixelWidth == 64)
    precondition(payload.pixelHeight == 32)
}

func checkVolcengineImagePayloadEncoderReencodesDataOverFourMillionBytes() {
    let compactPNG = try! makeImageData(width: 64, height: 32, type: .png)
    var oversizedData = compactPNG
    oversizedData.append(
        Data(
            repeating: 0,
            count: VolcengineImagePayloadEncoder.maximumByteCount
                - compactPNG.count
                + 1
        )
    )
    precondition(
        oversizedData.count
            == VolcengineImagePayloadEncoder.maximumByteCount + 1
    )

    let payload = try! VolcengineImagePayloadEncoder.encode(
        originalData: oversizedData
    )

    precondition(
        payload.data.count <= VolcengineImagePayloadEncoder.maximumByteCount
    )
    precondition(payload.data != oversizedData)
    precondition(payload.format == .png || payload.format == .jpeg)
}

func checkVolcengineImagePayloadEncoderScalesLongestEdgeTo4096() {
    let oversizedDimensions = try! makeImageData(
        width: VolcengineImagePayloadEncoder.maximumPixelDimension + 1,
        height: 2,
        type: .png
    )
    let payload = try! VolcengineImagePayloadEncoder.encode(
        originalData: oversizedDimensions
    )

    precondition(
        max(payload.pixelWidth, payload.pixelHeight)
            == VolcengineImagePayloadEncoder.maximumPixelDimension
    )
    precondition(
        payload.data.count <= VolcengineImagePayloadEncoder.maximumByteCount
    )
    precondition(payload.format == .png || payload.format == .jpeg)
}

func checkVolcengineImagePayloadEncoderConvertsOtherImageContainers() {
    let tiffData = try! makeImageData(width: 32, height: 16, type: .tiff)
    let payload = try! VolcengineImagePayloadEncoder.encode(
        originalData: tiffData
    )

    precondition(payload.format == .png)
    precondition(payload.data != tiffData)
    precondition(imageType(of: payload.data) == UTType.png.identifier)
}

private func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer {
        stream.close()
    }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            return nil
        }
        if count == 0 {
            break
        }
        body.append(buffer, count: count)
    }
    return body
}

private final class VolcengineRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func snapshot() -> [URLRequest] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return requests
    }
}

private final class VolcengineURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: (
        @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    )?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unknown)
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum VolcengineImageFixtureError: Error {
    case contextCreationFailed
    case imageCreationFailed
    case destinationCreationFailed
    case encodingFailed
}

private func makeImageData(
    width: Int,
    height: Int,
    type: UTType
) throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw VolcengineImageFixtureError.contextCreationFailed
    }
    context.setFillColor(CGColor(red: 0.18, green: 0.42, blue: 0.76, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        throw VolcengineImageFixtureError.imageCreationFailed
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        type.identifier as CFString,
        1,
        nil
    ) else {
        throw VolcengineImageFixtureError.destinationCreationFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw VolcengineImageFixtureError.encodingFailed
    }
    return data as Data
}

private func imageType(of data: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let type = CGImageSourceGetType(source) else {
        return nil
    }
    return type as String
}
