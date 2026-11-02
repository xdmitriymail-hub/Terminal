import Foundation
import Security
import LocalAuthentication

enum Keychain {
    @discardableResult
    static func save(_ data: Data, tag: String, biometry: Bool = false) -> Bool {
        delete(tag)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]

        if biometry {
            let acl = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                nil
            )
            if let acl {
                query[kSecAttrAccessControl as String] = acl
            }
        }

        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func save(_ string: String, tag: String, biometry: Bool = false) -> Bool {
        save(Data(string.utf8), tag: tag, biometry: biometry)
    }

    static func load(tag: String, context: LAContext? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    static func loadString(tag: String, context: LAContext? = nil) -> String? {
        load(tag: tag, context: context).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func delete(_ tag: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag
        ]
        SecItemDelete(query as CFDictionary)
    }
}
