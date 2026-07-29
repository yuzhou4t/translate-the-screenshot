import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct VolcengineImagePayload: Sendable, Equatable {
    enum Format: String, Sendable {
        case png
        case jpeg

        var mimeType: String {
            switch self {
            case .png:
                "image/png"
            case .jpeg:
                "image/jpeg"
            }
        }
    }

    var data: Data
    var format: Format
    var pixelWidth: Int
    var pixelHeight: Int
}

struct VolcengineImageTranslationResult: Sendable, Equatable {
    var imageData: Data
    var textBlocks: [VolcengineImageTextBlock]
    var responseMetadata: VolcengineImageResponseMetadata?
}

struct VolcengineImageTextBlock: Sendable, Equatable, Decodable {
    var points: [VolcengineImagePoint]
    var detectedLanguage: String
    var text: String
    var translation: String
    var foreColor: [Int32]
    var backColor: [Int32]

    enum CodingKeys: String, CodingKey {
        case points = "Points"
        case detectedLanguage = "DetectedLanguage"
        case text = "Text"
        case translation = "Translation"
        case foreColor = "ForeColor"
        case backColor = "BackColor"
    }
}

struct VolcengineImagePoint: Sendable, Equatable, Decodable {
    var x: Int32
    var y: Int32

    enum CodingKeys: String, CodingKey {
        case x = "X"
        case y = "Y"
    }
}

struct VolcengineImageResponseMetadata: Sendable, Equatable, Decodable {
    struct ErrorBody: Sendable, Equatable, Decodable {
        var code: String
        var message: String

        enum CodingKeys: String, CodingKey {
            case code = "Code"
            case message = "Message"
        }
    }

    var requestID: String?
    var action: String?
    var version: String?
    var service: String?
    var region: String?
    var error: ErrorBody?

    enum CodingKeys: String, CodingKey {
        case requestID = "RequestId"
        case action = "Action"
        case version = "Version"
        case service = "Service"
        case region = "Region"
        case error = "Error"
    }
}

struct VolcengineImageTranslationRequest: Encodable {
    var image: String
    var targetLanguage: String

    enum CodingKeys: String, CodingKey {
        case image = "Image"
        case targetLanguage = "TargetLanguage"
    }
}

struct VolcengineImageTranslationResponse: Decodable {
    var image: String?
    var textBlocks: [VolcengineImageTextBlock]?
    var responseMetadata: VolcengineImageResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case image = "Image"
        case textBlocks = "TextBlocks"
        case responseMetadata = "ResponseMetadata"
    }
}

struct VolcengineImageUsageRequest: Encodable {
    var service: String
    var from: Int
    var to: Int

    enum CodingKeys: String, CodingKey {
        case service = "Service"
        case from = "From"
        case to = "To"
    }
}

struct VolcengineImageUsageResponse: Decodable {
    struct Result: Decodable {
        struct Point: Decodable {
            var value: Int

            enum CodingKeys: String, CodingKey {
                case value = "Value"
            }
        }

        var points: [Point]

        enum CodingKeys: String, CodingKey {
            case points = "Points"
        }
    }

    var result: Result?
    var responseMetadata: VolcengineImageResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case result = "Result"
        case responseMetadata = "ResponseMetadata"
    }
}

enum VolcengineImagePayloadEncoder {
    static let maximumByteCount = 4_000_000
    static let maximumPixelDimension = 4_096

    static func encode(originalData: Data) throws -> VolcengineImagePayload {
        try Task.checkCancellation()
        guard !originalData.isEmpty,
              let source = CGImageSourceCreateWithData(originalData as CFData, nil),
              let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TranslationProviderError.providerMessage(
                "截图图片无法解码，火山图片翻译仅支持有效图片数据。"
            )
        }

        let originalFormat = format(for: CGImageSourceGetType(source))
        if let originalFormat,
           originalData.count <= maximumByteCount,
           max(sourceImage.width, sourceImage.height) <= maximumPixelDimension {
            return VolcengineImagePayload(
                data: originalData,
                format: originalFormat,
                pixelWidth: sourceImage.width,
                pixelHeight: sourceImage.height
            )
        }

        try Task.checkCancellation()
        guard var normalizedImage = resizedImage(
            sourceImage,
            maximumDimension: maximumPixelDimension,
            flattenTransparency: false
        ) else {
            throw TranslationProviderError.providerMessage(
                "截图图片缩放失败，无法满足火山图片翻译尺寸限制。"
            )
        }

        try Task.checkCancellation()
        if let pngData = encodedData(for: normalizedImage, format: .png),
           pngData.count <= maximumByteCount {
            return payload(data: pngData, format: .png, image: normalizedImage)
        }

        let jpegQualities: [CGFloat] = [0.92, 0.82, 0.70, 0.58, 0.45, 0.32]
        if let jpegPayload = try firstJPEGWithinLimit(
            image: normalizedImage,
            qualities: jpegQualities
        ) {
            return jpegPayload
        }

        while max(normalizedImage.width, normalizedImage.height) > 1 {
            try Task.checkCancellation()
            let nextMaximumDimension = max(
                1,
                Int(Double(max(normalizedImage.width, normalizedImage.height)) * 0.75)
            )
            guard let smallerImage = resizedImage(
                normalizedImage,
                maximumDimension: nextMaximumDimension,
                flattenTransparency: false
            ) else {
                break
            }
            normalizedImage = smallerImage

            if let jpegPayload = try firstJPEGWithinLimit(
                image: normalizedImage,
                qualities: jpegQualities
            ) {
                return jpegPayload
            }
        }

        throw TranslationProviderError.providerMessage(
            "截图图片压缩后仍超过 4,000,000 字节，无法发起火山图片翻译。"
        )
    }

    private static func format(for sourceType: CFString?) -> VolcengineImagePayload.Format? {
        guard let sourceType else {
            return nil
        }

        switch sourceType as String {
        case UTType.png.identifier:
            return .png
        case UTType.jpeg.identifier:
            return .jpeg
        default:
            return nil
        }
    }

    private static func firstJPEGWithinLimit(
        image: CGImage,
        qualities: [CGFloat]
    ) throws -> VolcengineImagePayload? {
        try Task.checkCancellation()
        guard let opaqueImage = resizedImage(
            image,
            maximumDimension: max(image.width, image.height),
            flattenTransparency: true
        ) else {
            return nil
        }

        for quality in qualities {
            try Task.checkCancellation()
            if let jpegData = encodedData(
                for: opaqueImage,
                format: .jpeg,
                quality: quality
            ),
               jpegData.count <= maximumByteCount {
                return payload(data: jpegData, format: .jpeg, image: opaqueImage)
            }
        }

        return nil
    }

    private static func payload(
        data: Data,
        format: VolcengineImagePayload.Format,
        image: CGImage
    ) -> VolcengineImagePayload {
        VolcengineImagePayload(
            data: data,
            format: format,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    private static func resizedImage(
        _ image: CGImage,
        maximumDimension: Int,
        flattenTransparency: Bool
    ) -> CGImage? {
        let scale = min(
            1,
            CGFloat(maximumDimension) / CGFloat(max(image.width, image.height))
        )
        let targetWidth = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let alphaInfo: CGImageAlphaInfo = flattenTransparency ? .noneSkipLast : .premultipliedLast

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: alphaInfo.rawValue
        ) else {
            return nil
        }

        if flattenTransparency {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(
                CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
            )
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        )
        return context.makeImage()
    }

    private static func encodedData(
        for image: CGImage,
        format: VolcengineImagePayload.Format,
        quality: CGFloat? = nil
    ) -> Data? {
        let destinationData = NSMutableData()
        let typeIdentifier: CFString
        switch format {
        case .png:
            typeIdentifier = UTType.png.identifier as CFString
        case .jpeg:
            typeIdentifier = UTType.jpeg.identifier as CFString
        }

        guard let destination = CGImageDestinationCreateWithData(
            destinationData,
            typeIdentifier,
            1,
            nil
        ) else {
            return nil
        }

        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return destinationData as Data
    }
}
