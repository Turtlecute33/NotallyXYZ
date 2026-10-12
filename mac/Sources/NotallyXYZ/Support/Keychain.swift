import Foundation
import Security

/// Stores the 32-byte sync key in the login Keychain, this device only.
enum Keychain {
    private static let service = "NotallyXYZ sync key"
    static let defaultAccount = "default"

    private static func baseQuery(dataProtection: Bool, account: String = defaultAccount) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    static func save(_ key: Data, account: String = defaultAccount) -> Bool {
        delete(account: account)
        for dataProtection in [true, false] {
            var q = baseQuery(dataProtection: dataProtection, account: account)
            q[kSecValueData as String] = key
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            q[kSecAttrLabel as String] = "NotallyXYZ sync key"
            let status = SecItemAdd(q as CFDictionary, nil)
            if status == errSecSuccess { return true }
            // The data protection keychain needs a team-signed app; fall back to the login keychain.
            if status != errSecMissingEntitlement { NSLog("NotallyXYZ: keychain add failed: \(status)") }
        }
        return false
    }

    static func load(account: String = defaultAccount) -> Data? {
        for dataProtection in [true, false] {
            var q = baseQuery(dataProtection: dataProtection, account: account)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 {
                return data
            }
        }
        return nil
    }

    static func delete(account: String = defaultAccount) {
        for dataProtection in [true, false] {
            SecItemDelete(baseQuery(dataProtection: dataProtection, account: account) as CFDictionary)
        }
    }
}
