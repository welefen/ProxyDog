import Foundation
import Security

/// Stores the AI API key in the login keychain, with a UserDefaults fallback for
/// environments where keychain access is denied.
enum AIKeychain {
    private static let service = "com.proxydog.app.ai"
    private static let account = "apiKey"
    private static let fallbackKey = "ai.apiKey"

    /// Attributes-only check: does not decrypt the password, so it does not prompt.
    static func exists() -> Bool {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess { return true }
        return UserDefaults.standard.string(forKey: fallbackKey)?.isEmpty == false
    }

    static func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        return UserDefaults.standard.string(forKey: fallbackKey)
    }

    static func save(_ value: String) {
        guard !value.isEmpty else {
            delete()
            return
        }
        let data = Data(value.utf8)
        var query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            if addStatus != errSecSuccess {
                UserDefaults.standard.set(value, forKey: fallbackKey)
                return
            }
        } else if updateStatus != errSecSuccess {
            UserDefaults.standard.set(value, forKey: fallbackKey)
            return
        }
        UserDefaults.standard.removeObject(forKey: fallbackKey)
    }

    static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
