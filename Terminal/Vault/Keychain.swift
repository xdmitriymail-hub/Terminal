import Foundation
import Security
import LocalAuthentication

enum Keychain {
    /// Suffix of the staging tag `migrateToAccessControl` uses while
    /// swapping an item. Orphan sweeps should treat it as ours.
    static let migrationBackupSuffix = ".vbackup"

    private static func query(_ tag: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag
        ]
    }

    /// Honest existence check: `errSecItemNotFound` means "absent".
    /// Anything else — `errSecInteractionNotAllowed` while locked,
    /// `errSecUserCanceled`, a broken ACL — is a real error and must
    /// never be read as "the item isn't there".
    static func itemStatus(tag: String) -> OSStatus {
        SecItemCopyMatching(query(tag) as CFDictionary, nil)
    }

    /// Update-in-place; add only when the item is truly absent. When a
    /// new ACL is required the item is migrated via a staged backup —
    /// the stored secret can never be destroyed by a failed add.
    @discardableResult
    static func save(_ data: Data, tag: String, biometry: Bool = false) -> OSStatus {
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

        switch itemStatus(tag: tag) {
        case errSecItemNotFound:
            return add(data, tag: tag, acl: acl)

        case errSecSuccess:
            if let acl, !hasAccessControl(tag: tag) {
                // SecItemUpdate can't attach an ACL — migrate safely.
                return migrateToAccessControl(data: data, tag: tag, acl: acl)
            }
            return SecItemUpdate(
                query(tag) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )

        case let status:
            // Locked keychain, denied access, …: report the real error
            // and touch nothing. Falling through to add/update here is
            // what used to destroy secrets.
            return status
        }
    }

    /// Adding an ACL can't be done by SecItemUpdate, and naive
    /// delete-before-add loses the secret if the add fails. Instead:
    ///   1. read the current secret (unreadable → abort, touch nothing)
    ///   2. stage it under a versioned backup tag (plain accessibility)
    ///   3. delete the original, add the new ACL'd item
    ///   4. on any add failure restore the original from the backup
    /// The backup is removed on success and swept by orphan cleanup if
    /// a crash ever leaves one behind.
    private static func migrateToAccessControl(data newData: Data, tag: String, acl: SecAccessControl) -> OSStatus {
        let backupTag = tag + migrationBackupSuffix

        var readQuery = query(tag)
        readQuery[kSecReturnData as String] = true
        var result: AnyObject?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard readStatus == errSecSuccess else { return readStatus }
        guard let oldData = result as? Data else { return errSecInternalError }

        _ = delete(backupTag)  // clear leftovers from a crashed migration
        var status = add(oldData, tag: backupTag, acl: nil)
        guard status == errSecSuccess else { return status }  // original intact

        status = delete(tag)
        guard status == errSecSuccess else {
            _ = delete(backupTag)
            return status                                     // original intact
        }

        status = add(newData, tag: tag, acl: acl)
        guard status == errSecSuccess else {
            // Restore the untouched original — no outcome where the
            // user's secret simply vanishes.
            _ = add(oldData, tag: tag, acl: nil)
            _ = delete(backupTag)
            return status
        }

        _ = delete(backupTag)
        return errSecSuccess
    }

    private static func add(_ data: Data, tag: String, acl: SecAccessControl?) -> OSStatus {
        var attributes = query(tag)
        attributes[kSecValueData as String] = data
        if let acl {
            attributes[kSecAttrAccessControl as String] = acl
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func hasAccessControl(tag: String) -> Bool {
        var attributesQuery = query(tag)
        attributesQuery[kSecReturnAttributes as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(attributesQuery as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [String: Any] else { return false }
        return attrs[kSecAttrAccessControl as String] != nil
    }

    @discardableResult
    static func save(_ string: String, tag: String, biometry: Bool = false) -> OSStatus {
        save(Data(string.utf8), tag: tag, biometry: biometry)
    }

    /// Full-fidelity load: `(nil, errSecItemNotFound)` is "no such
    /// item"; `(nil, any other status)` is a real failure —
    /// `errSecUserCanceled` included — and must NOT be treated as
    /// "the key is missing".
    static func loadWithStatus(tag: String, context: LAContext? = nil) -> (data: Data?, status: OSStatus) {
        var loadQuery = query(tag)
        loadQuery[kSecReturnData as String] = true
        loadQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            loadQuery[kSecUseAuthenticationContext as String] = context
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(loadQuery as CFDictionary, &result)
        guard status == errSecSuccess else {
            return (nil, status)
        }
        return (result as? Data, errSecSuccess)
    }

    static func load(tag: String, context: LAContext? = nil) -> Data? {
        loadWithStatus(tag: tag, context: context).data
    }

    static func loadString(tag: String, context: LAContext? = nil) -> String? {
        load(tag: tag, context: context).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Returns the real OSStatus (`errSecItemNotFound` when nothing was
    /// there) — a failed delete is a fact the caller deserves to know.
    @discardableResult
    static func delete(_ tag: String) -> OSStatus {
        SecItemDelete(query(tag) as CFDictionary)
    }

    /// Labeled-twin for call sites written as `delete(tag:)`.
    @discardableResult
    static func delete(tag: String) -> OSStatus {
        delete(tag)
    }
}
