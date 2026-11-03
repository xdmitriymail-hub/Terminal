import Combine
import Foundation
import UIKit

/// Versioned JSON persistence. Writes are atomic and always create the
/// file; an unreadable or corrupt file locks the store so a later save
/// can never clobber the user's data with an empty payload.
final class JSONStore<T: Codable> {
    /// Why a store is (or isn't) writable — and whether it can recover.
    enum State {
        /// No file yet — a fresh install, fully writable.
        case missing
        /// Decoded fine, or the last save succeeded — writable.
        case ready
        /// File exists but data protection denied the read (pre-first
        /// unlock). Retried by `retryAfterUnlock()`; never overwritten.
        case locked
        /// Exists but undecodable — preserved verbatim, never written.
        case corrupt
        /// A newer app wrote this file — payload readable, file read-only.
        case newerSchema
    }

    private struct Box: Codable {
        var version: Int
        var payload: T
    }

    private let url: URL
    private let version: Int
    private let migrate: ((Int, inout T) -> Void)?
    private let legacyDecode: ((Data) -> T?)?
    private let initial: T
    private let directoryError: Error?
    private let lock = NSLock()
    private var cached: T?

    private var _lastError: Error?
    private var _state: State = .missing

    /// Last persistence error, for surfacing in UI.
    var lastError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return _lastError
    }

    /// Why the store is refusing writes (`.missing`/`.ready` = fine).
    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// `legacyDecode` is a last-resort reader: when both the versioned
    /// box and a bare payload fail to decode strictly, it gets the raw
    /// file bytes and may return a payload rebuilt with defaults —
    /// used so a settings file written before a field existed never
    /// becomes unreadable.
    init(_ name: String,
         initial: T,
         version: Int = 1,
         directory: URL? = nil,
         legacyDecode: ((Data) -> T?)? = nil,
         migrate: ((Int, inout T) -> Void)? = nil) {
        self.initial = initial
        self.version = version
        self.migrate = migrate
        self.legacyDecode = legacyDecode
        let dir = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            directoryError = nil
        } catch {
            // NOT swallowed — load()/save() surface this via lastError
            // and every save refuses to pretend it worked.
            directoryError = error
        }
        url = dir.appendingPathComponent("\(name).json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: url.path
                )
            } catch {
                // Hardening only — every save already writes with
                // .completeFileProtection, so a miss here is harmless.
            }
        }
    }

    var writable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _state == .missing || _state == .ready
    }

    func load() -> T {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // No file yet — a fresh install, fully writable. A failed
            // directory creation still reaches the caller via lastError.
            _state = .missing
            _lastError = directoryError
            return initial
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
            // Locked (pre-first-unlock): recoverable — see retryAfterUnlock.
            _state = .locked
            _lastError = error
            return initial
        } catch {
            // Unreadable for any other reason — treat as corrupt.
            _state = .corrupt
            _lastError = error
            return initial
        }

        do {
            var box = try JSONDecoder().decode(Box.self, from: data)
            if box.version > version {
                // A newer app wrote this — expose the payload but never
                // clobber a schema we don't understand.
                _state = .newerSchema
                cached = box.payload
                return box.payload
            }
            if box.version < version {
                migrate?(box.version, &box.payload)
            }
            cached = box.payload
            _state = .ready
            _lastError = nil
            return box.payload
        } catch {
            let strictError = error
            // Legacy unversioned payload — the strict error stays the
            // one we report if everything below also fails.
            let legacy: T?
            do {
                legacy = try JSONDecoder().decode(T.self, from: data)
            } catch {
                legacy = nil
            }
            if let value = legacy {
                cached = value
                _state = .ready
                _lastError = nil
                return value
            }
            // Tolerant decode: an older schema may simply lack fields
            // added since — take their defaults instead of locking.
            if let value = legacyDecode?(data) {
                cached = value
                _state = .ready
                _lastError = nil
                return value
            }
            // Genuinely unreadable — never overwrite the user's data.
            _state = .corrupt
            _lastError = strictError
            return initial
        }
    }

    /// true only when the bytes actually hit disk. The in-memory cache
    /// is published AFTER a successful write — a failed save can no
    /// longer masquerade as the stored value.
    @discardableResult
    func save(_ value: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let directoryError {
            _lastError = directoryError
            return false
        }
        guard _state == .missing || _state == .ready else { return false }
        do {
            let data = try JSONEncoder().encode(Box(version: version, payload: value))
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            cached = value
            _state = .ready
            _lastError = nil
            return true
        } catch {
            // A failed write does NOT change state — it may be transient
            // (full disk, transient perms), and the cache stays honest
            // because it was never touched.
            _lastError = error
            return false
        }
    }

    /// Re-runs `load()` ONLY when the last failure was a data-protection
    /// lock — call from `protectedDataDidBecomeAvailable`. Corrupt and
    /// newer-schema states are deliberately untouched: recovering those
    /// is a user decision, not an automatic one. Returns true when a
    /// locked store actually recovered.
    @discardableResult
    func retryAfterUnlock() -> Bool {
        lock.lock()
        let isLocked = (_state == .locked)
        lock.unlock()
        guard isLocked else { return false }
        _ = load()
        return state != .locked
    }

    /// Raw bytes of a file we refuse to touch (corrupt or newer-schema)
    /// — enough for a recovery/export path that never overwrites it.
    func unrecoverableFileContents() -> Data? {
        lock.lock()
        let blocked = (_state == .corrupt || _state == .newerSchema)
        lock.unlock()
        guard blocked else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            return nil
        }
    }
}

/// Fires `body` on the main actor when protected data becomes available —
/// the hook every store uses to retry a `locked` persistence file.
private func onProtectedDataUnlock(_ body: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
        forName: UIApplication.protectedDataDidBecomeAvailableNotification,
        object: nil,
        queue: .main
    ) { _ in
        Task { @MainActor in body() }
    }
}

@MainActor
final class ProfilesStore: ObservableObject {
    @Published private(set) var profiles: [ServerProfile]
    /// Set whenever a persistence operation fails — alongside a `false`
    /// return so the UI can surface the failure instead of a fake "saved".
    @Published private(set) var storageError: Error?
    /// The on-disk file is corrupt, locked, or from a newer schema.
    var storageBlocked: Bool { !store.writable }
    /// Raw bytes of a blocked file — for a user-triggered export or
    /// rescue path; nil unless the store is corrupt/newer-schema.
    var unrecoverableData: Data? { store.unrecoverableFileContents() }

    private let store: JSONStore<[ServerProfile]>
    private var unlockObserver: NSObjectProtocol? = nil

    init(directory: URL? = nil) {
        let store = JSONStore<[ServerProfile]>("profiles", initial: [], directory: directory)
        self.store = store
        profiles = store.load()
        storageError = store.lastError
        unlockObserver = onProtectedDataUnlock { [weak self] in
            self?.reloadAfterUnlock()
        }
    }

    /// Retries a data-protection-locked file — and ONLY that state;
    /// corrupt/newer files are never touched automatically.
    func reloadAfterUnlock() {
        guard store.retryAfterUnlock() else { return }
        profiles = store.load()
        storageError = store.lastError
    }

    /// true only when the new list actually hit disk — the published
    /// array is updated after persistence, never before.
    @discardableResult
    func save(_ profile: ServerProfile) -> Bool {
        var candidate = profiles
        if let idx = candidate.firstIndex(where: { $0.id == profile.id }) {
            candidate[idx] = profile
        } else {
            candidate.append(profile)
        }
        guard store.save(candidate) else {
            storageError = store.lastError
            return false
        }
        profiles = candidate
        storageError = nil
        return true
    }

    /// Metadata removal is persisted FIRST; only then is the Keychain
    /// secret deleted. A failure can leave an orphaned password (swept
    /// later), never a profile pointing at a deleted secret.
    @discardableResult
    func delete(_ profile: ServerProfile) -> Bool {
        var candidate = profiles
        candidate.removeAll { $0.id == profile.id }
        guard store.save(candidate) else {
            storageError = store.lastError
            return false
        }
        profiles = candidate
        let status = Keychain.delete("password.\(profile.id.uuidString)")
        guard status == errSecSuccess || status == errSecItemNotFound else {
            storageError = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            return false
        }
        storageError = nil
        return true
    }

    @discardableResult
    func markConnected(_ id: UUID) -> Bool {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return true }
        var candidate = profiles
        candidate[idx].lastConnected = Date()
        guard store.save(candidate) else {
            storageError = store.lastError
            return false
        }
        profiles = candidate
        storageError = nil
        return true
    }
}

@MainActor
final class KeysStore: ObservableObject {
    @Published private(set) var keys: [StoredSSHKey]
    @Published private(set) var storageError: Error?
    var storageBlocked: Bool { !store.writable }
    var unrecoverableData: Data? { store.unrecoverableFileContents() }

    private let store: JSONStore<[StoredSSHKey]>
    private var unlockObserver: NSObjectProtocol? = nil

    init(directory: URL? = nil) {
        let store = JSONStore<[StoredSSHKey]>("keys", initial: [], directory: directory)
        self.store = store
        keys = store.load()
        storageError = store.lastError
        unlockObserver = onProtectedDataUnlock { [weak self] in
            self?.reloadAfterUnlock()
        }
        repairPublicKeyLines()
    }

    func reloadAfterUnlock() {
        guard store.retryAfterUnlock() else { return }
        keys = store.load()
        storageError = store.lastError
        repairPublicKeyLines()
    }

    /// Keys generated before the publicKeyLine fix carry a double-
    /// wrapped blob — `type base64(wire(type, wire(blob)))`. Unwrap
    /// one layer back to `type base64(blob)`; anything not matching
    /// that exact shape is left alone (imported keys were never bad).
    private func repairPublicKeyLines() {
        var repaired = keys
        var changed = false
        for i in repaired.indices {
            let line = repaired[i].publicKeyOpenSSH
            let parts = line.split(separator: " ")
            guard parts.count >= 2,
                  let outer = Data(base64Encoded: String(parts[1])) else { continue }
            var reader = SSHWireReader(outer)
            guard let outerType = try? reader.readText(),
                  outerType == parts[0],
                  let inner = try? reader.readString(),
                  reader.remaining == 0 else { continue }
            var innerReader = SSHWireReader(inner)
            guard let innerType = try? innerReader.readText(),
                  innerType == parts[0] else { continue }
            repaired[i].publicKeyOpenSSH = "\(parts[0]) \(inner.base64EncodedString())"
            changed = true
        }
        guard changed, store.save(repaired) else { return }
        keys = repaired
    }

    @discardableResult
    func save(_ key: StoredSSHKey) -> Bool {
        var candidate = keys
        if let idx = candidate.firstIndex(where: { $0.id == key.id }) {
            candidate[idx] = key
        } else {
            candidate.append(key)
        }
        guard store.save(candidate) else {
            storageError = store.lastError
            return false
        }
        keys = candidate
        storageError = nil
        return true
    }

    /// The metadata removal is committed to disk BEFORE the Keychain
    /// secret goes away — the reverse order could leave an entry that
    /// points at already-deleted material.
    @discardableResult
    func delete(_ key: StoredSSHKey) -> Bool {
        var candidate = keys
        candidate.removeAll { $0.id == key.id }
        guard store.save(candidate) else {
            storageError = store.lastError
            return false
        }
        keys = candidate
        let status = KeyVault.removeStoredSecrets(for: key)
        guard status == errSecSuccess else {
            // The secret may now be orphaned; sweep it rather than
            // resurrecting the metadata entry.
            storageError = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            return false
        }
        storageError = nil
        return true
    }

    /// Sweeps Keychain material whose tag no stored key references —
    /// e.g. secrets orphaned by a crash between metadata delete and
    /// secret delete. Returns the count removed. Never runs against an
    /// unreadable store: a corrupt `keys` file decodes to an empty
    /// list, and sweeping from it would wipe every stored secret.
    @discardableResult
    func removeOrphanedSecrets() -> Int {
        guard storageError == nil, unrecoverableData == nil else { return 0 }
        return KeyVault.removeOrphanedSecrets(keeping: Set(keys.flatMap {
            [$0.keychainTag, $0.passphraseTag]
        }))
    }

    func key(id: UUID?) -> StoredSSHKey? {
        guard let id else { return nil }
        return keys.first { $0.id == id }
    }
}

@MainActor
final class KnownHostsStore: ObservableObject {
    @Published private(set) var hosts: [KnownHost]
    @Published private(set) var storageError: Error?
    var storageBlocked: Bool { !store.writable }
    var unrecoverableData: Data? { store.unrecoverableFileContents() }

    private let store: JSONStore<[KnownHost]>
    private var unlockObserver: NSObjectProtocol? = nil

    init(directory: URL? = nil) {
        let store = JSONStore<[KnownHost]>("known_hosts", initial: [], directory: directory)
        self.store = store
        hosts = store.load()
        storageError = store.lastError
        unlockObserver = onProtectedDataUnlock { [weak self] in
            self?.reloadAfterUnlock()
        }
    }

    func reloadAfterUnlock() {
        guard store.retryAfterUnlock() else { return }
        hosts = store.load()
        storageError = store.lastError
    }

    /// Hostnames are case-insensitive — normalize before keying.
    private func key(_ host: String, _ port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    func known(host: String, port: Int) -> KnownHost? {
        hosts.first { $0.key == key(host, port) }
    }

    @discardableResult
    func trust(host: String, port: Int, publicKeyOpenSSH: String) -> Bool {
        var candidate = hosts
        if let idx = candidate.firstIndex(where: { $0.key == key(host, port) }) {
            candidate[idx].publicKeyOpenSSH = publicKeyOpenSSH
            candidate[idx].lastSeen = Date()
        } else {
            candidate.append(KnownHost(host: host.lowercased(), port: port, publicKeyOpenSSH: publicKeyOpenSSH))
        }
        guard store.save(candidate) else {
            storageError = store.lastError
            return false
        }
        hosts = candidate
        storageError = nil
        return true
    }

    @discardableResult
    func reset(host: String, port: Int) -> Bool {
        var candidate = hosts
        candidate.removeAll { $0.key == key(host, port) }
        guard store.save(candidate) else {
            storageError = store.lastError
            return false
        }
        hosts = candidate
        storageError = nil
        return true
    }
}

@MainActor
final class SnippetsStore: ObservableObject {
    @Published private(set) var snippets: [Snippet]
    @Published private(set) var storageError: Error?
    var storageBlocked: Bool { !store.writable }
    var unrecoverableData: Data? { store.unrecoverableFileContents() }

    private let store: JSONStore<[Snippet]>
    private var unlockObserver: NSObjectProtocol? = nil

    init(directory: URL? = nil) {
        let store = JSONStore<[Snippet]>("snippets", initial: [], directory: directory)
        self.store = store
        snippets = store.load()
        storageError = store.lastError
        unlockObserver = onProtectedDataUnlock { [weak self] in
            self?.reloadAfterUnlock()
        }
    }

    func reloadAfterUnlock() {
        guard store.retryAfterUnlock() else { return }
        snippets = store.load()
        storageError = store.lastError
    }

    @discardableResult
    func save(_ snippet: Snippet) -> Bool {
        var candidate = snippets
        if let idx = candidate.firstIndex(where: { $0.id == snippet.id }) {
            candidate[idx] = snippet
        } else {
            candidate.append(snippet)
        }
        guard store.save(candidate) else {
            storageError = store.lastError
            return false
        }
        snippets = candidate
        storageError = nil
        return true
    }

    @discardableResult
    func delete(_ snippet: Snippet) -> Bool {
        var candidate = snippets
        candidate.removeAll { $0.id == snippet.id }
        guard store.save(candidate) else {
            storageError = store.lastError
            return false
        }
        snippets = candidate
        storageError = nil
        return true
    }

    /// One write for reorder/move operations.
    @discardableResult
    func replaceAll(_ snippets: [Snippet]) -> Bool {
        guard store.save(snippets) else {
            storageError = store.lastError
            return false
        }
        self.snippets = snippets
        storageError = nil
        return true
    }
}

/// Every `AppSettings` field as an optional — a file written before a
/// field existed decodes cleanly and takes the current default for the
/// missing key instead of failing the whole payload.
private struct LegacyAppSettings: Decodable {
    var keepAlive: Bool?
    var requireBiometry: Bool?
    var autoTmux: Bool?
    var fontSize: Double?
    var themeID: String?
    var appearance: String?
    var haptics: Bool?
    var showKeyboardBar: Bool?
    var autoReconnect: Bool?
    var shellOverride: String?
    var remoteClipboard: Bool?

    func upgraded() -> AppSettings {
        var s = AppSettings()
        if let keepAlive { s.keepAlive = keepAlive }
        if let requireBiometry { s.requireBiometry = requireBiometry }
        if let autoTmux { s.autoTmux = autoTmux }
        if let fontSize { s.fontSize = fontSize }
        if let themeID { s.themeID = themeID }
        if let appearance, let value = AppSettings.Appearance(rawValue: appearance) {
            s.appearance = value
        }
        if let haptics { s.haptics = haptics }
        if let showKeyboardBar { s.showKeyboardBar = showKeyboardBar }
        if let autoReconnect { s.autoReconnect = autoReconnect }
        if let shellOverride { s.shellOverride = shellOverride }
        if let remoteClipboard { s.remoteClipboard = remoteClipboard }
        return s
    }
}

/// Versioned envelope whose payload is read tolerantly.
private struct LegacySettingsBox: Decodable {
    var version: Int
    var payload: LegacyAppSettings
}

@MainActor
final class SettingsStore: ObservableObject {
    /// Reads/writes through `_settings`, which stays @Published so the
    /// UI observes as before. The set path persists FIRST: a failed
    /// save is refused outright — the published value never moves to
    /// a state that didn't hit disk (no fake "saved" toggle).
    var settings: AppSettings {
        get { _settings }
        set {
            guard store.save(newValue) else {
                storageError = store.lastError
                return
            }
            _settings = newValue
            storageError = nil
        }
    }
    @Published private var _settings: AppSettings
    @Published private(set) var storageError: Error?
    var storageBlocked: Bool { !store.writable }
    var unrecoverableData: Data? { store.unrecoverableFileContents() }

    private let store: JSONStore<AppSettings>
    private var unlockObserver: NSObjectProtocol? = nil

    init(directory: URL? = nil) {
        let store = JSONStore<AppSettings>(
            "AppSettings",
            initial: AppSettings(),
            directory: directory,
            legacyDecode: { data in
                // nil simply means "still unreadable" — the strict
                // decode error above is the one that gets surfaced.
                do {
                    return try JSONDecoder().decode(LegacySettingsBox.self, from: data).payload.upgraded()
                } catch {
                    do {
                        return try JSONDecoder().decode(LegacyAppSettings.self, from: data).upgraded()
                    } catch {
                        return nil
                    }
                }
            }
        )
        self.store = store
        _settings = store.load()
        storageError = store.lastError
        unlockObserver = onProtectedDataUnlock { [weak self] in
            self?.reloadAfterUnlock()
        }
    }

    func reloadAfterUnlock() {
        guard store.retryAfterUnlock() else { return }
        _settings = store.load()
        storageError = store.lastError
    }
}
