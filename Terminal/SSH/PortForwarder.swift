import Foundation
import Network
import Citadel
import NIO
import NIOSSH

/// Bridges a NIO SSH channel to a Network.framework connection, both ways.
private final class NIOToNWBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let nw: NWConnection
    private var channel: Channel?

    init(nw: NWConnection) { self.nw = nw }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        startNWReceive(context.channel)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        let bytes = Data(buffer.readableBytesView)
        guard !bytes.isEmpty else { return }
        nw.send(content: bytes, completion: .contentProcessed { _ in })
    }

    func channelInactive(context: ChannelHandlerContext) {
        nw.cancel()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        nw.cancel()
    }

    private func startNWReceive(_ channel: Channel) {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] content, _, isComplete, _ in
            guard let self else { return }
            if let content, !content.isEmpty {
                channel.writeAndFlush(ByteBuffer(data: content), promise: nil)
            }
            if isComplete {
                channel.close(promise: nil)
            } else {
                self.startNWReceive(channel)
            }
        }
    }
}

/// Manages port forwarding rules for one SSH connection:
/// local (-L), remote (-R via Citadel) and dynamic SOCKS5 (-D).
@MainActor
final class PortForwardService: ObservableObject {
    struct Active: Identifiable {
        let id: UUID
        let rule: PortForward
        var task: Task<Void, Never>?
        var listener: NWListener?
    }

    @Published private(set) var active: [Active] = []

    private let connection: SSHConnection

    init(connection: SSHConnection) {
        self.connection = connection
    }

    func startAll(rules: [PortForward]) async {
        for rule in rules where rule.enabled {
            try? await start(rule)
        }
    }

    func start(_ rule: PortForward) async throws {
        guard !active.contains(where: { $0.id == rule.id }) else { return }
        var entry = Active(id: rule.id, rule: rule)
        switch rule.kind {
        case .local, .dynamic:
            entry.listener = try startListener(rule: rule)
        case .remote:
            entry.task = startRemote(rule: rule)
        }
        active.append(entry)
    }

    func stop(_ id: UUID) {
        guard let idx = active.firstIndex(where: { $0.id == id }) else { return }
        active[idx].task?.cancel()
        active[idx].listener?.cancel()
        active.remove(at: idx)
    }

    func stopAll() {
        for a in active {
            a.task?.cancel()
            a.listener?.cancel()
        }
        active.removeAll()
    }

    // MARK: - Local / Dynamic

    private func startListener(rule: PortForward) throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(clamping: rule.listenPort)))
        let listener = try NWListener(using: params)

        listener.newConnectionHandler = { [weak self] nw in
            guard let self else { return }
            switch rule.kind {
            case .local:
                Task { await self.forwardLocal(nw, rule: rule) }
            case .dynamic:
                Task { await self.handleSOCKS(nw) }
            case .remote: break
            }
        }
        listener.start(queue: DispatchQueue(label: "fwd.\(rule.listenPort)"))
        return listener
    }

    private func forwardLocal(_ nw: NWConnection, rule: PortForward) async {
        nw.start(queue: DispatchQueue(label: "fwd-conn"))
        do {
            let client = try await connection.ensureConnected()
            let origin = try SocketAddress(ipAddress: "127.0.0.1", port: Int(nw.endpoint.port?.rawValue ?? 0))
            _ = try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(
                    targetHost: rule.targetHost,
                    targetPort: rule.targetPort,
                    originatorAddress: origin
                )
            ) { channel in
                channel.pipeline.addHandler(NIOToNWBridge(nw: nw))
            }
        } catch {
            nw.cancel()
        }
    }

    // MARK: - Remote (-R)

    private func startRemote(rule: PortForward) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await connection.ensureConnected()
                // Bind on the server's loopback — `ssh -R` defaults to
                // loopback too; wildcard would expose the port network-wide.
                try await client.runRemotePortForward(
                    host: "127.0.0.1",
                    port: rule.listenPort,
                    forwardingTo: rule.targetHost,
                    port: rule.targetPort
                )
            } catch { }
        }
    }

    // MARK: - SOCKS5 (-D)

    private func handleSOCKS(_ nw: NWConnection) async {
        nw.start(queue: DispatchQueue(label: "socks-conn"))
        do {
            guard let request = try await Socks5.negotiate(on: nw) else {
                nw.cancel()
                return
            }
            let client = try await connection.ensureConnected()
            let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            _ = try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(
                    targetHost: request.host,
                    targetPort: request.port,
                    originatorAddress: origin
                )
            ) { channel in
                channel.pipeline.addHandler(NIOToNWBridge(nw: nw))
            }
            try await Socks5.sendSuccess(on: nw)
        } catch {
            try? await Socks5.sendFailure(on: nw)
            nw.cancel()
        }
    }
}

/// Minimal SOCKS5 server-side handshake (no-auth, CONNECT only).
private enum Socks5 {
    struct Request {
        let host: String
        let port: Int
    }

    /// Buffered reader: a single NW receive can return greeting + request
    /// in one datagram — surplus bytes must be kept for the next field.
    final class BufferedReader {
        private let nw: NWConnection
        private var buffer = Data()

        init(on nw: NWConnection) { self.nw = nw }

        private func receiveMore(min: Int) async throws -> Data {
            try await withCheckedThrowingContinuation { cont in
                nw.receive(minimumIncompleteLength: min, maximumLength: 512) { data, _, _, error in
                    if let data, !data.isEmpty { cont.resume(returning: data) }
                    else { cont.resume(throwing: error ?? CancellationError()) }
                }
            }
        }

        func read(_ count: Int) async throws -> Data {
            while buffer.count < count {
                buffer.append(try await receiveMore(min: count - buffer.count))
            }
            let out = buffer.prefix(count)
            buffer.removeFirst(count)
            return Data(out)
        }
    }

    /// Returns the CONNECT target after method-negotiation, or nil on failure.
    static func negotiate(on nw: NWConnection) async throws -> Request? {
        let reader = BufferedReader(on: nw)
        let greeting = try await reader.read(2)
        guard greeting[0] == 0x05 else { return nil }
        let methods = try await reader.read(Int(greeting[1]))
        guard methods.contains(0x00) else { return nil }
        // choose "no auth"
        nw.send(content: Data([0x05, 0x00]), completion: .contentProcessed { _ in })

        let header = try await reader.read(4)
        guard header[0] == 0x05, header[1] == 0x01 else { return nil }

        var host: String
        var portBytes: Data
        switch header[3] {
        case 0x01: // IPv4
            let rest = try await reader.read(6)
            host = rest.prefix(4).map(String.init).joined(separator: ".")
            portBytes = rest.suffix(2)
        case 0x03: // domain
            let len = Int(try await reader.read(1)[0])
            guard len > 0 else { return nil }
            let rest = try await reader.read(len + 2)
            host = String(data: rest.prefix(len), encoding: .utf8) ?? ""
            portBytes = rest.suffix(2)
        case 0x04: // IPv6
            let rest = try await reader.read(18)
            var addr = in6_addr()
            _ = withUnsafeMutableBytes(of: &addr) { ptr in
                ptr.copyBytes(from: rest.prefix(16))
            }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var copy = addr
            host = inet_ntop(AF_INET6, &copy, &buf, socklen_t(INET6_ADDRSTRLEN)).map { String(cString: $0) } ?? ""
            portBytes = rest.suffix(2)
        default:
            return nil
        }

        guard !host.isEmpty, portBytes.count == 2 else { return nil }
        let port = Int(portBytes[0]) << 8 | Int(portBytes[1])
        return Request(host: host, port: port)
    }

    static func sendSuccess(on nw: NWConnection) async throws {
        let reply = Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nw.send(content: reply, completion: .contentProcessed { error in
                error == nil ? cont.resume() : cont.resume(throwing: error!)
            })
        }
    }

    static func sendFailure(on nw: NWConnection) async throws {
        let reply = Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        nw.send(content: reply, completion: .contentProcessed { _ in })
    }
}
