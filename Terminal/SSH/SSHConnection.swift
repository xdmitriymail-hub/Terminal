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

    /// Citadel's authenticationMethod closure is synchronous, while reading
    /// keys/passwords is async (Keychain + biometry). We prepare the method
    /// once per connect attempt.
    func prepareAuth() async throws {
        preparedAuth = try await authMethodFor(profile)
    }

    @discardableResult
    func ensureConnected() async throws -> Citadel.SSHClient {
        if let client, client.isConnected { return client }
        if let connectTask { return try await connectTask.value }

        let task = Task<Citadel.SSHClient, Error> {
            defer { connectTask = nil }
            setState(.connecting)
            do {
                let connected = try await performConnect()
                // Cancelled mid-handshake (tab closed): adopt nothing —
                // the just-finished transport would become an orphan.
                if Task.isCancelled {
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

    private func performConnect() async throws -> Citadel.SSHClient {
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
            // The bastion needs its own credentials prepared too —
            // without this it would attempt an empty-password auth.
            try await bastion.prepareAuth()
            let hop = try await bastion.ensureConnected()
            return try await hop.jump(to: settings)
        }
        return try await SSHClient.connect(to: settings)
    }

    // MARK: - Channels

    func openShell(cols: Int, rows: Int) async throws -> ShellChannel {
        try await prepareAuth()
        let client = try await ensureConnected()
        let shell = ShellChannel()
        try await shell.open(on: client, cols: cols, rows: rows)
        return shell
    }

    func openSFTP() async throws -> Citadel.SFTPClient {
        try await prepareAuth()
        let client = try await ensureConnected()
        return try await client.openSFTP()
    }

    func execute(_ command: String) async throws -> String {
        try await prepareAuth()
        let client = try await ensureConnected()
        let buffer = try await client.executeCommand(command, inShell: false)
        return String(buffer: buffer)
    }

    func close() async {
        try? await client?.close()
        client = nil
        setState(.offline)
    }

    func markDisconnected() {
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
