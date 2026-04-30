import AppKit
import Foundation

struct VisionImagePayload {
    var mimeType: String
    var base64Data: String

    var dataURL: String {
        "data:\(mimeType);base64,\(base64Data)"
    }
}

enum VisionImagePayloadEncoder {
    static func encode(_ image: NSImage) throws -> VisionImagePayload {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw TranslationProviderError.providerMessage("截图图片编码失败，无法发起视觉分块请求。")
        }

        return VisionImagePayload(
            mimeType: "image/png",
            base64Data: pngData.base64EncodedString()
        )
    }
}
