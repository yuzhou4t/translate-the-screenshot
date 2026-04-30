import Foundation
import Security

enum KeychainServiceError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                "钥匙串错误：\(message)"
            } else {
                "钥匙串错误：\(status)"
            }
        case .invalidData:
            "无法读取钥匙串中保存的 API Key。"
        }
    }
}

final class KeychainService {
    private let service = "tts.translation-providers"
    private let userDefaults: UserDefaults
    private let cachePrefix = "tts.localSecretCache."

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func saveAPIKey(_ apiKey: String, for providerID: TranslationProviderID) throws {
        try saveAPIKey(apiKey, account: providerID.rawValue)
    }

    func saveAPIKey(_ apiKey: String, account: String) throws {
        saveCachedAPIKey(apiKey, account: account)

        let data = Data(apiKey.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                return
            }
            return
        }

        return
    }

    func loadAPIKey(for providerID: TranslationProviderID) throws -> String? {
        try loadAPIKey(account: providerID.rawValue)
    }

    func loadAPIKey(account: String) throws -> String? {
        if let cached = cachedAPIKey(account: account),
           !cached.isEmpty {
            return cached
        }

        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainServiceError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8) else {
            throw KeychainServiceError.invalidData
        }

        saveCachedAPIKey(apiKey, account: account)
        return apiKey
    }

    func deleteAPIKey(for providerID: TranslationProviderID) throws {
        try deleteAPIKey(account: providerID.rawValue)
    }

    func deleteAPIKey(account: String) throws {
        deleteCachedAPIKey(account: account)

        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func cachedAPIKey(account: String) -> String? {
        userDefaults.string(forKey: cacheKey(account: account))
    }

    private func saveCachedAPIKey(_ apiKey: String, account: String) {
        userDefaults.set(apiKey, forKey: cacheKey(account: account))
    }

    private func deleteCachedAPIKey(account: String) {
        userDefaults.removeObject(forKey: cacheKey(account: account))
    }

    private func cacheKey(account: String) -> String {
        cachePrefix + Data(account.utf8).base64EncodedString()
    }
}
