import Foundation

final class JSONStore<T: Codable> {
    private let url: URL
    private let queue = DispatchQueue(label: "jsonstore", qos: .utility)
    private var cached: T?
    private let initial: T

    init(_ name: String, initial: T) {
        self.initial = initial
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("\(name).json")
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    func load() -> T {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(T.self, from: data) else {
            return initial
        }
        cached = value
        return value
    }

    func save(_ value: T) {
        cached = value
        queue.async { [url] in
            guard let data = try? JSONEncoder().encode(value) else { return }
            let tmp = url.appendingPathExtension("tmp")
            try? data.write(to: tmp, options: [.completeFileProtection])
            try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        }
    }
}

@MainActor
final class ProfilesStore: ObservableObject {
    @Published private(set) var profiles: [ServerProfile]
    private let store = JSONStore("profiles", initial: [ServerProfile]())

    init() { profiles = store.load() }

    func save(_ profile: ServerProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        store.save(profiles)
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

    func save(_ key: StoredSSHKey) {
        if let idx = keys.firstIndex(where: { $0.id == key.id }) {
            keys[idx] = key
        } else {
            keys.append(key)
        }
        store.save(keys)
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

    func save(_ snippet: Snippet) {
        if let idx = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[idx] = snippet
        } else {
            snippets.append(snippet)
        }
        store.save(snippets)
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
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
