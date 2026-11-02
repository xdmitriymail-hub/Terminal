import Foundation
import Security
import LocalAuthentication

enum Keychain {
    /// Update-in-place; add only when the item doesn't exist yet — a
    /// failed add can no longer destroy the stored secret.
    @discardableResult
    static func save(_ data: Data, tag: String, biometry: Bool = false) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag
        ]

        var acl: SecAccessControl?
        if biometry {
            guard let created = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                nil
            ) else { return errSecParam }
            acl = created
        }

        let exists = SecItemCopyMatching(
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrAccount as String: tag] as CFDictionary,
            nil
        ) == errSecSuccess

        if exists, !(biometry && !hasAccessControl(tag: tag)) {
            return SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }

        // Either no item yet, or it lacks the ACL now required: the
        // update path can't attach an ACL, so replace in that case only.
        if exists { delete(tag) }
        query[kSecValueData as String] = data
        if let acl {
            query[kSecAttrAccessControl as String] = acl
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return SecItemAdd(query as CFDictionary, nil)
    }

    private static func hasAccessControl(tag: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnAttributes as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [String: Any] else { return false }
        return attrs[kSecAttrAccessControl as String] != nil
    }

    @discardableResult
    static func save(_ string: String, tag: String, biometry: Bool = false) -> OSStatus {
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
