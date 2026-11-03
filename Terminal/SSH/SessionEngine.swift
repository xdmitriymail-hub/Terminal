import Combine
import Foundation
import Network
import UIKit
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
    private var observerTokens: [NSObjectProtocol] = []

    /// A pending host-key decision: id makes resume exactly-once, the
    /// owning profile lets a dead connect retire precisely its prompt.
    private struct PendingHostKey {
        let profileID: UUID
        let event: HostKeyEvent
        let resume: (Bool) -> Void
    }
    private var pendingHostKeys: [UUID: PendingHostKey] = [:]

    /// Sessions waiting on a password, per connection — a terminated
    /// session's request is retired instead of left hanging.
    private var passwordQueue: [UUID] = []

    /// Published mirror of passwordQueue — UI that must react to a
    /// prompt appearing/clearing (connect ring, dismiss flows) subscribes
    /// here rather than polling session state.
    @Published private(set) var awaitingPasswordIDs: Set<UUID> = []

    let profiles: ProfilesStore
    let keys: KeysStore
    let knownHosts: KnownHostsStore
    let settings: SettingsStore

    /// Set by UI layer: asks the user to confirm unknown/changed host keys.
    var hostKeyDecider: (@MainActor (HostKeyEvent) async -> Bool)?

    /// Set by UI layer: the prompt for this event was resolved or
    /// cancelled underneath it — remove that dialog only, without
    /// answering. A sibling server's pending prompt is untouched.
    var onHostKeyPromptDismissed: (@Sendable (HostKeyEvent) -> Void)?

    /// Set by UI layer: the pending password prompt must come down
    /// (its session terminated or authenticated through another path).
    var onPasswordPromptDismissed: (@Sendable () -> Void)?

    /// Set by UI layer: surface an error as a gentle alert.
    var onError: (@MainActor (String) -> Void)?

    /// Set by UI layer: a session needs the password it doesn't have —
    /// ask the user, store it, then let the session retry.
    var onAuthNeeded: (@MainActor (TerminalSession) -> Void)?

    /// Set by UI layer: the remote host wants to write the clipboard —
    /// the user confirms once per session.
    var onClipboardRequest: (@MainActor (TerminalSession, Data) -> Void)?

    /// tmux presence per profile — detected once, reused across tabs.
    /// Only a *successful* probe is cached: a timed-out exec leaves the
    /// entry empty so the next connect probes again instead of
    /// inheriting a false "no tmux" that orphans server sessions.
    private var tmuxAvailable: [UUID: Bool] = [:]

    /// Consecutive probe failures per profile — one timed-out probe is
    /// a strike, not a verdict. Reset on success or when the transport
    /// is declared dead; a mere successful handshake does not clear it,
    /// so a flapping link can't churn reconnects forever.
    private var probeFailures: [UUID: Int] = [:]

    /// One exec round-trip per connect learns tmux presence and OS
    /// identity. The tmux answer is cached per profile (execs cost a
    /// channel each); OS is learned once and persisted on the profile.
    func probeHost(_ session: TerminalSession) async -> TerminalSession.RemoteProbe {
        if let cached = tmuxAvailable[session.profile.id],
           session.profile.osID != nil {
            return TerminalSession.RemoteProbe(hasTmux: cached)
        }
        let probe = await session.probeRemote()
        if let found = probe.hasTmux {
            tmuxAvailable[session.profile.id] = found
        }
        if session.profile.osID == nil,
           let osID = probe.osID, let osName = probe.osName {
            var updated = session.profile
            updated.osID = osID
            updated.osName = osName
            _ = profiles.save(updated)
            session.retarget(profile: updated, connection: session.connection)
        }
        return probe
    }

    init(profiles: ProfilesStore, keys: KeysStore, knownHosts: KnownHostsStore, settings: SettingsStore) {
        self.profiles = profiles
        self.keys = keys
        self.knownHosts = knownHosts
        self.settings = settings
        startPathMonitor()
        startKeepAlive()
        observeLifecycle()
    }

    deinit {
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
        keepAliveTimer?.invalidate()
        pathMonitor?.cancel()
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
            validatorFor: { [weak self] profile in
                guard let self else {
                    return HostKeyTrustValidator(host: profile.host, port: profile.port, knownKey: nil) { _ in false }
                }
                return await self.makeValidator(for: profile)
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
            onStateChange: { [weak self] state in
                Task { @MainActor in
                    self?.transportStateChanged(profileID: profile.id, state: state)
                }
            },
            onConnectSettled: { [weak self] in
                Task { @MainActor in
                    self?.cancelHostKeyPrompts(profileID: profile.id)
                }
            }
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
            // Never ship an empty password — the caller prompts first.
            // Distinguish "no password stored" from a locked/denied
            // keychain: only the former should ask the user to type one.
            let tag = "password.\(profile.id.uuidString)"
            let (data, status) = Keychain.loadWithStatus(tag: tag)
            guard status == errSecSuccess else {
                // Same OSStatus mapping as KeyVault.loadMaterial: a
                // cancelled/denied prompt is an auth gate, never a
                // transport failure worth retrying against.
                switch status {
                case errSecItemNotFound:
                    throw KeyVaultError.keyMaterialMissing
                case errSecUserCanceled, errSecInteractionNotAllowed:
                    throw KeyVaultError.biometricDenied
                default:
                    throw KeyVaultError.keychainFailure(status)
                }
            }
            guard let password = data.flatMap({ String(data: $0, encoding: .utf8) }),
                  !password.isEmpty else {
                throw KeyVaultError.keyMaterialMissing
            }
            return .passwordBased(username: profile.username, password: password)
        case .key(let keyID):
            guard let stored = keys.key(id: keyID) else {
                throw KeyVaultError.keyMaterialMissing
            }
            return try await KeyVault.authenticationMethod(for: stored, username: profile.username)
        }
    }

    // MARK: - Host key prompts

    private func makeValidator(for profile: ServerProfile) -> NIOSSHClientServerAuthenticationDelegate {
        let known = knownHosts.known(host: profile.host, port: profile.port)?.publicKeyOpenSSH
        return HostKeyTrustValidator(host: profile.host, port: profile.port, knownKey: known) { [weak self] event in
            guard let self else { return false }
            return await self.decideHostKey(profileID: profile.id, event: event)
        }
    }

    /// Races the UI answer against connection teardown: whichever lands
    /// first resumes the continuation; the loser finds the slot gone.
    private func decideHostKey(profileID: UUID, event: HostKeyEvent) async -> Bool {
        await withCheckedContinuation { cont in
            let requestID = UUID()
            pendingHostKeys[requestID] = PendingHostKey(profileID: profileID, event: event) { answer in
                cont.resume(returning: answer)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let answer = await self.hostKeyDecider?(event) ?? false
                self.resolveHostKeyPrompt(requestID, answer: answer)
            }
        }
    }

    private func resolveHostKeyPrompt(_ id: UUID, answer: Bool) {
        guard let pending = pendingHostKeys.removeValue(forKey: id) else { return }
        if answer {
            persistTrust(for: pending.event)
        }
        pending.resume(answer)
    }

    /// Trust persistence must never silently masquerade as permanent:
    /// a failed save still applies to this handshake, but the key is
    /// NOT in the store — the next connect asks again, and the user is
    /// told why instead of assuming the key stuck.
    private func persistTrust(for event: HostKeyEvent) {
        switch event {
        case .unknown(let host, let port, let line, _),
             .changed(let host, let port, let line, _, _):
            if !knownHosts.trust(host: host, port: port, publicKeyOpenSSH: line) {
                onError?("Couldn't save the host key — you'll be asked again")
            }
        }
    }

    /// Every pending prompt owned by this profile resolves as rejected
    /// and the UI is told to drop the dialog — a closed tab never
    /// leaves a frozen trust sheet behind.
    private func cancelHostKeyPrompts(profileID: UUID) {
        let doomed = pendingHostKeys.filter { $0.value.profileID == profileID }
        guard !doomed.isEmpty else { return }
        for (id, pending) in doomed {
            pendingHostKeys[id] = nil
            pending.resume(false)
            // The UI keys its prompt queue by the event — only the
            // prompt belonging to this dead connect is dismissed, so
            // a concurrent handshake's ask is never resolved for it.
            onHostKeyPromptDismissed?(pending.event)
        }
    }

    // MARK: - Password prompts

    /// Queues the session's auth request and lets the UI ask. Every
    /// call is a genuine new ask — a stale queue entry left by a
    /// user-dismissed prompt must never suppress it.
    func authNeeded(_ session: TerminalSession) {
        if !passwordQueue.contains(session.id) {
            passwordQueue.append(session.id)
            awaitingPasswordIDs.insert(session.id)
        }
        onAuthNeeded?(session)
    }

    /// True while this session's password prompt is outstanding — the
    /// host row keeps its "connecting" affordance instead of snapping
    /// to a red error the prompt may yet resolve.
    func isAwaitingPassword(_ session: TerminalSession) -> Bool {
        passwordQueue.contains(session.id)
    }

    /// Retires a session's password request — authenticated, cancelled
    /// by the user, or terminated. The UI drops any prompt it shows.
    func clearPasswordPrompt(for session: TerminalSession) {
        guard passwordQueue.contains(session.id) else { return }
        passwordQueue.removeAll { $0 == session.id }
        awaitingPasswordIDs.remove(session.id)
        onPasswordPromptDismissed?()
    }

    /// A session is going away: its pending prompts die with it.
    func sessionTerminated(_ session: TerminalSession) {
        clearPasswordPrompt(for: session)
    }

    /// Drops the cached tmux answer for a profile (e.g. after a rebuild).
    func resetTmuxCache(for profileID: UUID) {
        tmuxAvailable[profileID] = nil
    }

    /// A saved profile reached open tabs: the stale pooled transport is
    /// dropped first, then every session of that profile is pointed at
    /// a freshly-built one so changed host, port, user or key apply.
    /// The old transport's close lands after the retarget — sessions
    /// retry through the new connection.
    func retargetSessions(for profile: ServerProfile) {
        invalidateConnection(for: profile.id)
        let conn = connection(for: profile)
        for session in sessions where session.profile.id == profile.id {
            session.retarget(profile: profile, connection: conn)
        }
    }

    /// Drops a pooled transport (e.g. when profile secrets changed).
    func invalidateConnection(for profileID: UUID) {
        probeFailures[profileID] = nil
        tmuxAvailable[profileID] = nil
        cancelHostKeyPrompts(profileID: profileID)
        if let service = forwardServices.removeValue(forKey: profileID) {
            Task { await service.stopAll() }
        }
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
        session.start(cols: cols, rows: rows)
        Task {
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
        await service.applyRules(profile.forwards)
    }

    /// Called when a profile's forward rules change — refreshes the set.
    /// Refreshes serialize inside the service; a stale result never
    /// overwrites a newer rule state.
    func refreshForwards(for profile: ServerProfile) async {
        guard let service = forwardServices[profile.id] else {
            await applyForwards(for: profile)
            return
        }
        await service.applyRules(profile.forwards)
    }

    /// Live runtime state for the UI: rule id → starting/ready/failed.
    func forwardRuntime(for profile: ServerProfile) -> [UUID: ForwardRuntimeState] {
        forwardServices[profile.id]?.runtime ?? [:]
    }

    /// The service object itself, for UI that wants @Published updates.
    func forwardsService(for profile: ServerProfile) -> PortForwardService? {
        forwardServices[profile.id]
    }

    /// Surfaces a readable session failure as a quiet alert.
    func reportError(_ message: String) {
        onError?(message)
    }

    /// A session's state flipped: republish so `engine`-level
    /// observers (keepalive activity sync, host-row badges) re-read —
    /// `sessions` itself only emits when tabs come and go, not when a
    /// live tab's state changes.
    func sessionActivityDidChange() {
        objectWillChange.send()
    }

    func closeSession(_ session: TerminalSession) {
        session.terminate()
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id {
            activeSessionID = sessions.last?.id
        }
    }

    // MARK: - Resilience

    /// The pooled transport changed state: online re-applies forwards
    /// (remote rules live per-transport); offline tells live sessions
    /// their transport is gone so retry can start before the channel's
    /// own close event even lands.
    private func transportStateChanged(profileID: UUID, state: SSHConnection.State) {
        switch state {
        case .online:
            guard let profile = profiles.profiles.first(where: { $0.id == profileID }) else { return }
            Task { await applyForwards(for: profile) }
        case .offline:
            for session in sessions where session.profile.id == profileID {
                session.noteTransportLost()
            }
        case .connecting:
            break
        }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumeForegroundWork()
                await self?.probeConnections()
            }
        })
        observerTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.suspendBackgroundWork()
            }
        })
    }

    /// Backgrounding stops the probe cadence and abandons in-flight
    /// probes — suspended sockets shouldn't hold channels open.
    private func suspendBackgroundWork() async {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        for (_, conn) in connections {
            await conn.cancelProbe()
        }
    }

    private func resumeForegroundWork() {
        if keepAliveTimer == nil {
            startKeepAlive()
        }
    }

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

    /// After a network change or foregrounding, verify pooled
    /// connections still answer; silently reconnect dead ones so
    /// sessions come back instantly.
    private func probeConnections() async {
        await probeAllConnections()
        guard settings.settings.autoReconnect else { return }
        for session in sessions where session.wantsReconnect {
            await session.reconnectIfNeeded()
        }
    }

    /// A pending prompt for this profile — host-key or password — means
    /// a connect is legitimately waiting on the user, not stuck. Probing
    /// now would race the answer against a transport teardown.
    private func hasPendingPrompt(for profileID: UUID) -> Bool {
        if pendingHostKeys.values.contains(where: { $0.profileID == profileID }) {
            return true
        }
        return sessions.contains { $0.profile.id == profileID && passwordQueue.contains($0.id) }
    }

    /// A connection that is no longer up is dropped so the next channel
    /// re-handshakes. A live shell is not probed with `true`: that exec
    /// times out on a slow host and used to disconnect a session the
    /// user was still typing in.
    private func probeAllConnections() async {
        for (profileID, conn) in connections {
            guard await !conn.isConnecting,
                  !hasPendingPrompt(for: profileID) else { continue }
            guard await conn.isConnected else {
                probeFailures[profileID] = nil
                await conn.markDisconnected()
                continue
            }
            // A live shell is the liveness signal. An extra `true` that
            // times out must not tear the session down.
        }
    }

    private func startKeepAlive() {
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.probeConnections()
            }
        }
        keepAliveTimer?.tolerance = 5
    }
}
