import Combine
import Foundation

/// Versioned JSON persistence. Writes are atomic and always create the
/// file; an unreadable or corrupt file locks the store so a later save
/// can never clobber the user's data with an empty payload.
final class JSONStore<T: Codable> {
    private struct Box: Codable {
        var version: Int
        var payload: T
    }

    private let url: URL
    private let version: Int
    private let migrate: ((Int, inout T) -> Void)?
    private let initial: T
    private let lock = NSLock()
    private var cached: T?
    private var blocked = false

    /// Last persistence error, for surfacing in UI.
    private(set) var lastError: Error?

    init(_ name: String, initial: T, version: Int = 1, directory: URL? = nil, migrate: ((Int, inout T) -> Void)? = nil) {
        self.initial = initial
        self.version = version
        self.migrate = migrate
        let dir = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("\(name).json")
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    var writable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !blocked
    }

    func load() -> T {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        do {
            let data = try Data(contentsOf: url)
            do {
                var box = try JSONDecoder().decode(Box.self, from: data)
                if box.version > version {
                    // A newer app wrote this — don't clobber a schema we
                    // don't understand.
                    blocked = true
                    return box.payload
                }
                if box.version < version {
                    migrate?(box.version, &box.payload)
                }
                cached = box.payload
                return box.payload
            } catch {
                // Legacy unversioned payload.
                let value = try JSONDecoder().decode(T.self, from: data)
                cached = value
                return value
            }
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // No file yet — a fresh install, fully writable.
            return initial
        } catch {
            // Locked (pre-first-unlock) or corrupt: never overwrite.
            blocked = true
            lastError = error
            return initial
        }
    }

    @discardableResult
    func save(_ value: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        cached = value
        guard !blocked else { return false }
        do {
            let data = try JSONEncoder().encode(Box(version: version, payload: value))
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            lastError = nil
            return true
        } catch {
            lastError = error
            return false
        }
    }
}

@MainActor
final class ProfilesStore: ObservableObject {
    @Published private(set) var profiles: [ServerProfile]
    private let store = JSONStore("profiles", initial: [ServerProfile]())

    var storageError: Error? { store.lastError }

    init() { profiles = store.load() }

    @discardableResult
    func save(_ profile: ServerProfile) -> Bool {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        return store.save(profiles)
    }

    func delete(_ profile: ServerProfile) {
        profiles.removeAll { $0.id == profile.id }
        Keychain.delete("password.\(profile.id.uuidString)")
        store.save(profiles)
    }

    func markConnected(_ id: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].lastConnected = Date()
        store.save(profiles)
    }
}

@MainActor
final class KeysStore: ObservableObject {
    @Published private(set) var keys: [StoredSSHKey]
    private let store = JSONStore("keys", initial: [StoredSSHKey]())

    init() { keys = store.load() }

    @discardableResult
    func save(_ key: StoredSSHKey) -> Bool {
        if let idx = keys.firstIndex(where: { $0.id == key.id }) {
            keys[idx] = key
        } else {
            keys.append(key)
        }
        return store.save(keys)
    }

    func delete(_ key: StoredSSHKey) {
        keys.removeAll { $0.id == key.id }
        Keychain.delete(key.keychainTag)
        Keychain.delete(key.passphraseTag)
        store.save(keys)
    }

    func key(id: UUID?) -> StoredSSHKey? {
        guard let id else { return nil }
        return keys.first { $0.id == id }
    }
}

@MainActor
final class KnownHostsStore: ObservableObject {
    @Published private(set) var hosts: [KnownHost]
    private let store = JSONStore("known_hosts", initial: [KnownHost]())

    init() { hosts = store.load() }

    /// Hostnames are case-insensitive — normalize before keying.
    private func key(_ host: String, _ port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    func known(host: String, port: Int) -> KnownHost? {
        hosts.first { $0.key == key(host, port) }
    }

    func trust(host: String, port: Int, publicKeyOpenSSH: String) {
        if let idx = hosts.firstIndex(where: { $0.key == key(host, port) }) {
            hosts[idx].publicKeyOpenSSH = publicKeyOpenSSH
            hosts[idx].lastSeen = Date()
        } else {
            hosts.append(KnownHost(host: host.lowercased(), port: port, publicKeyOpenSSH: publicKeyOpenSSH))
        }
        store.save(hosts)
    }

    func reset(host: String, port: Int) {
        hosts.removeAll { $0.key == key(host, port) }
        store.save(hosts)
    }
}

@MainActor
final class SnippetsStore: ObservableObject {
    @Published private(set) var snippets: [Snippet]
    private let store = JSONStore("snippets", initial: [Snippet]())

    init() { snippets = store.load() }

    @discardableResult
    func save(_ snippet: Snippet) -> Bool {
        if let idx = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[idx] = snippet
        } else {
            snippets.append(snippet)
        }
        return store.save(snippets)
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        store.save(snippets)
    }

    /// One write for reorder/move operations.
    func replaceAll(_ snippets: [Snippet]) {
        self.snippets = snippets
        store.save(snippets)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { store.save(settings) }
    }
    private let store = JSONStore("AppSettings", initial: AppSettings())

    init() { settings = store.load() }
}
