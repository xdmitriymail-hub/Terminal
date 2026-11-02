import Combine
import Foundation
import Network
import Citadel
import NIOSSH

/// Global session/connection pool. Owns SSHConnection per profile
/// (multiplexing), watches network path changes and drives reconnects.
@MainActor
final class SessionEngine: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var activeSessionID: UUID?

    private var connections: [UUID: SSHConnection] = [:]
    private var forwardServices: [UUID: PortForwardService] = [:]
    private var pathMonitor: NWPathMonitor?
    private var keepAliveTimer: Timer?

    let profiles: ProfilesStore
    let keys: KeysStore
    let knownHosts: KnownHostsStore
    let settings: SettingsStore

    /// Set by UI layer: asks the user to confirm unknown/changed host keys.
    var hostKeyDecider: (@MainActor (HostKeyEvent) async -> Bool)?

    /// Set by UI layer: surface an error as a gentle alert.
    var onError: (@MainActor (String) -> Void)?

    init(profiles: ProfilesStore, keys: KeysStore, knownHosts: KnownHostsStore, settings: SettingsStore) {
        self.profiles = profiles
        self.keys = keys
        self.knownHosts = knownHosts
        self.settings = settings
        startPathMonitor()
        startKeepAlive()
    }

    // MARK: - Connection pool

    func connection(for profile: ServerProfile) -> SSHConnection {
        if let existing = connections[profile.id] { return existing }
        let connection = SSHConnection(
            profile: profile,
            authMethodFor: { [weak self] profile in
                guard let self else { throw KeyVaultError.keyMaterialMissing }
                return try await self.buildAuth(for: profile)
            },
            validatorFor: { [weak self] host, port in
                guard let self else {
                    return HostKeyTrustValidator(host: host, port: port, knownKey: nil) { _ in false }
                }
                return await self.makeValidator(host: host, port: port)
            },
            bastionResolver: { [weak self] jumpID in
                guard let self, let jumpProfile = await self.profiles.profiles.first(where: { $0.id == jumpID }) else {
                    throw SSHClientError.channelCreationFailed
                }
                // A jump chain that loops back to this profile would
                // recurse forever — break it before connecting.
                guard await !self.jumpChainLoops(from: jumpProfile, backTo: profile.id) else {
                    throw SSHClientError.channelCreationFailed
                }
                return await self.connection(for: jumpProfile)
            },
            onStateChange: { _ in }
        )
        connections[profile.id] = connection
        return connection
    }

    /// Walks the profile's jump chain: true if it ever reaches `targetID`
    /// (including a self-hop) — a cycle that must not be connected.
    private func jumpChainLoops(from start: ServerProfile, backTo targetID: UUID) -> Bool {
        var current: ServerProfile? = start
        var seen: Set<UUID> = [targetID]
        while let profile = current {
            guard seen.insert(profile.id).inserted else { return true }
            current = profile.jumpProfileID.flatMap { id in
                profiles.profiles.first { $0.id == id }
            }
        }
        return false
    }

    private func buildAuth(for profile: ServerProfile) async throws -> SSHAuthenticationMethod {
        switch profile.auth {
        case .password:
            let password = Keychain.loadString(tag: "password.\(profile.id.uuidString)") ?? ""
            return .passwordBased(username: profile.username, password: password)
        case .key(let keyID):
            guard let stored = keys.key(id: keyID) else {
                throw KeyVaultError.keyMaterialMissing
            }
            return try KeyVault.authenticationMethod(for: stored, username: profile.username)
        }
    }

    private func makeValidator(host: String, port: Int) -> NIOSSHClientServerAuthenticationDelegate {
        let known = knownHosts.known(host: host, port: port)?.publicKeyOpenSSH
        return HostKeyTrustValidator(host: host, port: port, knownKey: known) { [weak self] event in
            guard let self else { return false }
            switch event {
            case .unknown(let h, let p, let line, _):
                if await (self.hostKeyDecider?(event) ?? false) {
                    await self.knownHosts.trust(host: h, port: p, publicKeyOpenSSH: line)
                    return true
                }
                return false
            case .changed(let h, let p, let line, _, _):
                if await (self.hostKeyDecider?(event) ?? false) {
                    await self.knownHosts.trust(host: h, port: p, publicKeyOpenSSH: line)
                    return true
                }
                return false
            }
        }
    }

    /// Called by the UI when the user accepts a changed key: re-pin and allow.
    func trustReplacement(host: String, port: Int, keyLine: String) {
        knownHosts.trust(host: host, port: port, publicKeyOpenSSH: keyLine)
    }

    /// Drops a pooled transport (e.g. when profile secrets changed).
    func invalidateConnection(for profileID: UUID) {
        forwardServices[profileID]?.stopAll()
        forwardServices[profileID] = nil
        if let conn = connections.removeValue(forKey: profileID) {
            Task { await conn.close() }
        }
    }

    // MARK: - Sessions

    @discardableResult
    func openSession(for profile: ServerProfile, cols: Int, rows: Int) -> TerminalSession {
        let conn = connection(for: profile)
        let session = TerminalSession(profile: profile, connection: conn, settings: settings)
        session.engine = self
        sessions.append(session)
        activeSessionID = session.id
        profiles.markConnected(profile.id)
        Task {
            await session.start(cols: cols, rows: rows)
            await applyForwards(for: profile)
        }
        return session
    }

    /// Applies the profile's enabled forwarding rules on the pooled
    /// connection (created lazily, survives reconnects via re-apply).
    private func applyForwards(for profile: ServerProfile) async {
        guard profile.forwards.contains(where: \.enabled) else { return }
        let service = forwardServices[profile.id] ?? PortForwardService(connection: connection(for: profile))
        forwardServices[profile.id] = service
        await service.startAll(rules: profile.forwards)
    }

    /// Called when a profile's forward rules change — restarts the set.
    func refreshForwards(for profile: ServerProfile) async {
        guard let service = forwardServices[profile.id] else {
            await applyForwards(for: profile)
            return
        }
        service.stopAll()
        await service.startAll(rules: profile.forwards)
    }

    /// Surfaces a readable session failure as a quiet alert.
    func reportError(_ message: String) {
        onError?(message)
    }

    func closeSession(_ session: TerminalSession) {
        session.terminate()
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id {
            activeSessionID = sessions.last?.id
        }
    }

    // MARK: - Resilience

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                await self.probeConnections()
            }
        }
        monitor.start(queue: DispatchQueue(label: "pathmonitor", qos: .utility))
        pathMonitor = monitor
    }

    /// After a network change, verify pooled connections still answer;
    /// silently reconnect dead ones so sessions come back instantly.
    private func probeConnections() async {
        for (_, conn) in connections {
            if await !conn.isConnected {
                await conn.markDisconnected()
            }
        }
        for session in sessions where session.wantsReconnect {
            await session.reconnectIfNeeded()
        }
    }

    private func startKeepAlive() {
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sessions.forEach { $0.keepAlive() }
            }
        }
        keepAliveTimer?.tolerance = 5
    }
}
