import Foundation
import Security

enum TTCustomKeychain {
    private static let service = "com.derrick.ttcustom.server-credentials"

    static func load(host: String, username: String) -> String {
        let account = "\(host)\n\(username)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return ""
        }
        return password
    }

    @discardableResult
    static func save(_ password: String, host: String, username: String) -> Bool {
        let account = "\(host)\n\(username)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return true }
        let item = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

