import Foundation
import Citadel
import NIO
import NIOSSH

/// One multiplexed SSH transport to a profile: terminals, SFTP and
/// forwards share the single connection. Reconnects are transparent.
actor SSHConnection {
    enum State: Sendable, Equatable {
        case offline, connecting, online
    }

    let profile: ServerProfile
    private(set) var state: State = .offline

    private var client: Citadel.SSHClient?
    private var preparedAuth: SSHAuthenticationMethod?
    /// Single in-flight connect: concurrent ensureConnected() callers
    /// share one handshake instead of racing duplicate transports.
    private var connectTask: Task<Citadel.SSHClient, Error>?
    /// Bumped by close()/markDisconnected() — a late-finishing handshake
    /// from an older generation is dropped instead of adopted.
    private var generation = 0

    private let authMethodFor: @Sendable (ServerProfile) async throws -> SSHAuthenticationMethod
    private let validatorFor: @Sendable (String, Int) async -> NIOSSHClientServerAuthenticationDelegate
    private let bastionResolver: @Sendable (UUID) async throws -> SSHConnection
    private let onStateChange: @Sendable (State) -> Void

    init(
        profile: ServerProfile,
        authMethodFor: @escaping @Sendable (ServerProfile) async throws -> SSHAuthenticationMethod,
        validatorFor: @escaping @Sendable (String, Int) async -> NIOSSHClientServerAuthenticationDelegate,
        bastionResolver: @escaping @Sendable (UUID) async throws -> SSHConnection,
        onStateChange: @escaping @Sendable (State) -> Void
    ) {
        self.profile = profile
        self.authMethodFor = authMethodFor
        self.validatorFor = validatorFor
        self.bastionResolver = bastionResolver
        self.onStateChange = onStateChange
    }

    var isConnected: Bool { client?.isConnected == true }

    private func setState(_ s: State) {
        state = s
        onStateChange(s)
    }

    @discardableResult
    func ensureConnected() async throws -> Citadel.SSHClient {
        if let client, client.isConnected { return client }
        if let connectTask { return try await connectTask.value }

        generation += 1
        let gen = generation
        let task = Task<Citadel.SSHClient, Error> {
            defer { connectTask = nil }
            setState(.connecting)
            do {
                let connected = try await performConnect()
                // Cancelled mid-handshake or superseded by a newer
                // generation: adopt nothing — the finished transport
                // would become an orphan.
                if Task.isCancelled || gen != generation {
                    Task { try? await connected.close() }
                    throw CancellationError()
                }
                client = connected
                setState(.online)
                return connected
            } catch {
                setState(.offline)
                throw error
            }
        }
        connectTask = task
        return try await task.value
    }

    /// Citadel's authenticationMethod closure is synchronous, while reading
    /// keys/passwords is async (Keychain + biometry). The method is prepared
    /// inside the connect task so callers never re-authenticate against an
    /// already-live transport, and cleared right after the handshake so
    /// secrets aren't retained for the connection's lifetime.
    private func performConnect() async throws -> Citadel.SSHClient {
        preparedAuth = try await authMethodFor(profile)
        defer { preparedAuth = nil }
        guard let auth = preparedAuth else { throw KeyVaultError.keyMaterialMissing }
        let validator = await validatorFor(profile.host, profile.port)

        var settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { auth },
            hostKeyValidator: .custom(validator)
        )
        // Strict crypto posture: the bundled algorithm set is already the
        // allowlist we want — AES256/128-GCM transport, ECDH + Curve25519
        // KEX, ed25519/ECDSA host keys. Citadel's `.all` would re-add
        // AES-CTR, group14-sha1 and ssh-rsa — deliberately not used.
        settings.connectTimeout = .seconds(12)

        if let jumpID = profile.jumpProfileID {
            let bastion = try await bastionResolver(jumpID)
            let hop = try await bastion.ensureConnected()
            return try await hop.jump(to: settings)
        }
        return try await SSHClient.connect(to: settings)
    }

    /// Opens a channel on the live transport; only a reused transport that
    /// turned out half-dead is dropped and retried once — failures on a
    /// fresh handshake (auth, host key, channel limits) surface as-is.
    private func withTransport<T>(_ work: (Citadel.SSHClient) async throws -> T) async throws -> T {
        let reused = client?.isConnected == true
        do {
            return try await work(ensureConnected())
        } catch {
            guard reused else { throw error }
            await markDisconnected()
            return try await work(ensureConnected())
        }
    }

    // MARK: - Channels

    func openShell(cols: Int, rows: Int) async throws -> ShellChannel {
        try await withTransport { client in
            let shell = ShellChannel()
            try await shell.open(on: client, cols: cols, rows: rows)
            return shell
        }
    }

    func openSFTP() async throws -> Citadel.SFTPClient {
        try await withTransport { try await $0.openSFTP() }
    }

    func execute(_ command: String) async throws -> String {
        try await withTransport {
            String(buffer: try await $0.executeCommand(command, inShell: false))
        }
    }

    /// Real transport probe: a no-op remote command proves auth and the
    /// channel machinery still work — TCP-level liveness alone lies.
    func probe() async -> Bool {
        guard let client, client.isConnected else { return false }
        do {
            _ = try await withTimeout(.seconds(8)) {
                try await client.executeCommand("true", inShell: false)
            }
            return true
        } catch {
            return false
        }
    }

    private func withTimeout<T>(_ timeout: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func close() async {
        generation += 1
        preparedAuth = nil
        connectTask?.cancel()
        connectTask = nil
        try? await client?.close()
        client = nil
        setState(.offline)
    }

    func markDisconnected() {
        generation += 1
        preparedAuth = nil
        let old = client
        client = nil
        connectTask?.cancel()
        connectTask = nil
        setState(.offline)
        if let old {
            Task { try? await old.close() }
        }
    }
}
