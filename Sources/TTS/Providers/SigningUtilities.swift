import CryptoKit
import Foundation

enum SigningUtilities {
    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256(key: Data, message: String) -> Data {
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        )
        return Data(signature)
    }

    static func hmacSHA256Hex(key: Data, message: String) -> String {
        hmacSHA256(key: key, message: message)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
