import Combine
import Foundation
import Network
import Citadel
import NIO
import NIOConcurrencyHelpers
import NIOSSH

/// Live per-rule state for the UI: a forward is `starting` until its
/// listener is bound (or the remote accepted the request), then `ready`
/// — it never advertises a tunnel that isn't actually up.
enum ForwardRuntimeState: Equatable, Sendable {
    case starting, ready, failed(String), stopped
}

/// Bridges a NIO SSH channel to a Network.framework connection, both
/// ways, with real backpressure in both directions:
///
/// * NIO→NW: autoRead is off — the next chunk is only read after the
///   previous NW send completes, so a slow client can't balloon buffers.
/// * NW→NIO: the next receive is issued only after the channel write
///   flushes, and pauses entirely while the channel is unwritable.
/// * EOF propagates as half-close: client EOF closes channel output
///   (SSH EOF) while remote bytes still flow; remote inputClosed stops
///   inbound but the client may keep writing until it's done.
///
/// `gated` mode holds bridging closed until `begin` is called — SOCKS
/// uses it to keep the reply before any proxied data on the wire.
///
/// Handler callbacks hop between the channel's event loop and NW's
/// queue, so all mutable state sits in a `NIOLockedValueBox` — that is
/// what makes the `Sendable` conformance honest instead of `@unchecked`.
/// The lock is only ever held to read/mutate flags, never across a NIO
/// or NW call whose completion might re-enter it.
private final class NIOToNWBridge: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    private struct State {
        var started = false
        /// Remote bytes that arrived while the gate was closed —
        /// replayed to the client right after the SOCKS reply, before
        /// live data.
        var earlyInbound = Data()
        var tearingDown = false
        var clientEOF = false
        var remoteEOF = false
        /// A NW receive deferred because the channel went unwritable.
        var receiveDeferred = false
    }

    private let nw: NWConnection
    private let gated: Bool
    private let state = NIOLockedValueBox(State())
    private let onClose: @Sendable () -> Void

    init(nw: NWConnection, gated: Bool, onClose: @escaping @Sendable () -> Void = {}) {
        self.nw = nw
        self.gated = gated
        self.onClose = onClose
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if !gated {
            state.withLockedValue { $0.started = true }
            startNWReceive(on: context.channel)
        }
        // Paced reads: nothing inbound is consumed unless asked for.
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { [weak self, weak channel = context.channel] _ in
            guard let self, let channel else { return }
            if self.state.withLockedValue({ $0.started }) { channel.read() }
        }
    }

    /// Opens the gate: client surplus goes first (it was sent before
    /// everything else client-side), buffered remote bytes replay after
    /// it, then live bridging starts in both directions.
    func begin(surplus: Data, on channel: Channel) {
        let early: Data? = state.withLockedValue { s in
            guard !s.started else { return nil }
            s.started = true
            defer { s.earlyInbound.removeAll(keepingCapacity: false) }
            return s.earlyInbound
        }
        guard let early else { return }
        if !surplus.isEmpty {
            channel.writeAndFlush(ByteBuffer(data: surplus)).whenComplete { [weak self, weak channel] result in
                guard let self, let channel else { return }
                if case .failure = result { self.teardown(channel) }
            }
        }
        if !early.isEmpty {
            sendToNW(early, on: channel)
        }
        startNWReceive(on: channel)
        channel.read()
    }

    // MARK: - NIO → NW

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        guard !bytes.isEmpty else {
            context.read()
            return
        }
        let gateClosed = state.withLockedValue { s -> Bool in
            guard s.started else {
                s.earlyInbound.append(bytes)
                return true
            }
            return false
        }
        if gateClosed {
            context.read()
            return
        }
        sendToNW(bytes, on: context.channel)
    }

    /// The next inbound chunk is only read once this send completes —
    /// backpressure against a slow or dead client.
    private func sendToNW(_ bytes: Data, on channel: Channel) {
        nw.send(content: bytes, completion: .contentProcessed { [weak self, weak channel] error in
            guard let self, let channel else { return }
            channel.eventLoop.execute {
                if error != nil {
                    self.teardown(channel)
                    return
                }
                if self.state.withLockedValue({ $0.started && !$0.tearingDown }) {
                    channel.read()
                }
            }
        })
    }

    // MARK: - NW → NIO

    private func startNWReceive(on channel: Channel) {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak channel] content, _, isComplete, error in
            guard let self, let channel else { return }
            channel.eventLoop.execute {
                self.handleNWReceive(content: content, isComplete: isComplete, error: error, on: channel)
            }
        }
    }

    private func handleNWReceive(content: Data?, isComplete: Bool, error: NWError?, on channel: Channel) {
        if error != nil {
            // Receive errors are real: the client died mid-stream, and
            // silently re-arming a receive would spin forever.
            teardown(channel)
            return
        }
        if let content, !content.isEmpty {
            channel.writeAndFlush(ByteBuffer(data: content)).whenComplete { [weak self, weak channel] result in
                guard let self, let channel else { return }
                switch result {
                case .success:
                    if self.state.withLockedValue({ $0.tearingDown }) { return }
                    if channel.isWritable {
                        self.startNWReceive(on: channel)
                    } else {
                        // Writability wins: no further receives until
                        // the channel drains and reports writable again.
                        self.state.withLockedValue { $0.receiveDeferred = true }
                    }
                case .failure:
                    self.teardown(channel)
                }
            }
            return
        }
        if isComplete {
            // Client EOF → SSH half-close: the remote may still be
            // talking, so only our output side ends here.
            let shouldTeardown = state.withLockedValue { s -> Bool in
                s.clientEOF = true
                return s.remoteEOF
            }
            if shouldTeardown {
                teardown(channel)
            } else {
                channel.close(mode: .output).whenComplete { [weak self, weak channel] _ in
                    guard let self, let channel else { return }
                    if self.state.withLockedValue({ $0.remoteEOF }) { self.teardown(channel) }
                }
            }
            return
        }
        startNWReceive(on: channel)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        let resume = state.withLockedValue { s -> Bool in
            guard s.receiveDeferred else { return false }
            s.receiveDeferred = false
            return true
        }
        if context.channel.isWritable, resume {
            startNWReceive(on: context.channel)
        }
        context.fireChannelWritabilityChanged()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed {
            // Remote EOF: no more inbound data, but the client may
            // still be writing — don't kill that direction.
            let both = state.withLockedValue { s -> Bool in
                s.remoteEOF = true
                return s.clientEOF
            }
            if both { teardown(context.channel) }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        teardown(context.channel)
        context.fireChannelInactive()
    }

    /// The handler leaving the pipeline ends the bridge no matter which
    /// side tore it down — NW doesn't outlive its SSH channel.
    func handlerRemoved(context: ChannelHandlerContext) {
        teardownNW()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        teardown(context.channel)
    }

    /// Full teardown, exactly once: channel and NW both go.
    private func teardown(_ channel: Channel) {
        let go = state.withLockedValue { s -> Bool in
            guard !s.tearingDown else { return false }
            s.tearingDown = true
            return true
        }
        guard go else { return }
        nw.cancel()
        channel.close(promise: nil)
        onClose()
    }

    /// Teardown without a live channel (handlerRemoved — the channel
    /// is already going away on its own).
    private func teardownNW() {
        let go = state.withLockedValue { s -> Bool in
            guard !s.tearingDown else { return false }
            s.tearingDown = true
            return true
        }
        guard go else { return }
        nw.cancel()
        onClose()
    }
}

/// Manages port forwarding rules for one SSH connection:
/// local (-L), remote (-R via Citadel) and dynamic SOCKS5 (-D).
/// Runtime state per rule is published for the UI; accepted
/// connections are tracked so stop() actually tears them down.
@MainActor
final class PortForwardService: ObservableObject {
    struct Active: Identifiable {
        let id: UUID
        let rule: PortForward
        var task: Task<Void, Never>?
        var listener: NWListener?
    }

    @Published private(set) var active: [Active] = []
    @Published private(set) var runtime: [UUID: ForwardRuntimeState] = [:]

    private let connection: SSHConnection
    /// Every accepted socket, by id, with its owning rule — stop()
    /// kills these too, not just the listener that spawned them.
    private var accepted: [UUID: NWConnection] = [:]
    private var acceptedRule: [UUID: UUID] = [:]
    /// Refreshes serialize; each active entry carries a generation so
    /// a stale start/stop result never overwrites a newer rule.
    private var applyTask: Task<Void, Never>?
    private var entrySerial: [UUID: Int] = [:]
    private var entryCounter = 0
    private var socksInFlight = 0
    private static let maxSOCKSHandshakes = 32
    private static let handshakeTimeout: Duration = .seconds(15)
    private static let maxRemoteRetries = 8
    private var stopped = false

    init(connection: SSHConnection) {
        self.connection = connection
    }

    /// Serialized rule refresh: applies run one at a time, in call
    /// order, and entries started by an older refresh can't clobber
    /// newer runtime state.
    func applyRules(_ rules: [PortForward]) async {
        let previous = applyTask
        let task = Task { [weak self] in
            _ = await previous?.value
            await self?.performApply(rules)
        }
        applyTask = task
        await task.value
    }

    private func performApply(_ rules: [PortForward]) async {
        guard !stopped else { return }
        let enabled = rules.filter { $0.enabled }
        let wanted = Set(enabled.map(\.id))
        // Disabled or deleted rules stop — and teardown is awaited, so
        // listeners, tasks and accepted connections really are gone.
        for entry in active where !wanted.contains(entry.id) {
            await teardown(entry.id, outcome: .stopped)
        }
        for rule in enabled {
            guard !stopped else { return }
            if let existing = active.first(where: { $0.id == rule.id }) {
                if existing.rule == rule { continue }
                await teardown(rule.id, outcome: .stopped)
            }
            await start(rule)
        }
        for id in runtime.keys where !rules.contains(where: { $0.id == id }) {
            runtime[id] = nil
            entrySerial[id] = nil
        }
    }

    /// Stops one rule and awaits its teardown — listener, task and
    /// every accepted connection it spawned.
    func stop(_ id: UUID) async {
        await teardown(id, outcome: .stopped)
    }

    /// Stops everything and awaits completion: the service is retired.
    func stopAll() async {
        stopped = true
        applyTask?.cancel()
        _ = await applyTask?.value
        // Iterates a snapshot — teardown mutates `active` as it goes.
        for entry in active {
            await teardown(entry.id, outcome: .stopped)
        }
        for (_, conn) in accepted {
            conn.cancel()
        }
        accepted.removeAll()
        acceptedRule.removeAll()
        runtime.removeAll()
        entrySerial.removeAll()
    }

    private func teardown(_ id: UUID, outcome: ForwardRuntimeState) async {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return }
        let entry = active.remove(at: index)
        entrySerial[id] = nil
        runtime[id] = outcome
        for (connID, conn) in accepted where acceptedRule[connID] == id {
            conn.cancel()
        }
        if let listener = entry.listener {
            listener.newConnectionHandler = nil
            // `.cancelled` normally arrives promptly; a wedged listener
            // must not hang stop()/stopAll() forever, so the wait is
            // bounded — cancel still landed, just unconfirmed.
            try? await withTimeout(.seconds(5)) {
                await cancelListener(listener)
            }
        }
        if let task = entry.task {
            task.cancel()
            _ = await task.value
        }
    }

    /// A cancelled listener reaches `.cancelled` asynchronously — stop
    /// only completes once the port is actually released.
    private func cancelListener(_ listener: NWListener) async {
        await withCheckedContinuation { cont in
            listener.stateUpdateHandler = { state in
                if case .cancelled = state {
                    cont.resume()
                }
            }
            listener.cancel()
        }
    }

    /// Runtime updates are generation-guarded: a task or listener
    /// callback from an entry that has since been replaced is dropped.
    private func setRuntime(_ id: UUID, _ state: ForwardRuntimeState, entryGen: Int) {
        guard entrySerial[id] == entryGen else { return }
        runtime[id] = state
    }

    private func start(_ rule: PortForward) async {
        guard !stopped else { return }
        entryCounter += 1
        let entryGen = entryCounter
        entrySerial[rule.id] = entryGen
        var entry = Active(id: rule.id, rule: rule)
        runtime[rule.id] = .starting
        do {
            switch rule.kind {
            case .local, .dynamic:
                entry.listener = try startListener(rule: rule, entryGen: entryGen)
            case .remote:
                entry.task = startRemote(rule: rule, entryGen: entryGen)
            }
            active.append(entry)
        } catch {
            runtime[rule.id] = .failed("Port \(rule.listenPort) unavailable")
        }
    }

    // MARK: - Accepted connections

    private func trackAccepted(_ nw: NWConnection, ruleID: UUID) -> UUID {
        let id = UUID()
        accepted[id] = nw
        acceptedRule[id] = ruleID
        nw.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                Task { @MainActor in self.forgetAccepted(id) }
            default:
                break
            }
        }
        return id
    }

    private func forgetAccepted(_ id: UUID) {
        accepted[id] = nil
        acceptedRule[id] = nil
    }

    // MARK: - Local / Dynamic

    private func startListener(rule: PortForward, entryGen: Int) throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(clamping: rule.listenPort)))
        let listener = try NWListener(using: params)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    self.setRuntime(rule.id, .ready, entryGen: entryGen)
                case .failed:
                    self.setRuntime(rule.id, .failed("Port \(rule.listenPort) unavailable"), entryGen: entryGen)
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] nw in
            guard let self else { return }
            switch rule.kind {
            case .local:
                Task { await self.forwardLocal(nw, rule: rule) }
            case .dynamic:
                Task { await self.handleSOCKS(nw, rule: rule) }
            case .remote: break
            }
        }
        listener.start(queue: DispatchQueue(label: "fwd.\(rule.listenPort)"))
        return listener
    }

    private func forwardLocal(_ nw: NWConnection, rule: PortForward) async {
        let connID = trackAccepted(nw, ruleID: rule.id)
        nw.start(queue: DispatchQueue(label: "fwd-conn"))
        await withTaskCancellationHandler {
            defer { forgetAccepted(connID) }
            do {
                let client = try await withTimeout(Self.handshakeTimeout) {
                    try await connection.ensureConnected()
                }
                var peerPort = 0
                if case .hostPort(_, let port) = nw.endpoint { peerPort = Int(port.rawValue) }
                let origin = try SocketAddress(ipAddress: "127.0.0.1", port: peerPort)
                let bridge = NIOToNWBridge(nw: nw, gated: false) { [weak self] in
                    Task { @MainActor in self?.forgetAccepted(connID) }
                }
                let channel = try await client.createDirectTCPIPChannel(
                    using: SSHChannelType.DirectTCPIP(
                        targetHost: rule.targetHost,
                        targetPort: rule.targetPort,
                        originatorAddress: origin
                    )
                ) { channel in
                    channel.pipeline.addHandler(bridge)
                }
                // The bridge owns the data path now; holding the task
                // on closeFuture keeps accepted-connection tracking
                // accurate for the connection's real lifetime.
                try await channel.closeFuture.get()
            } catch {
                nw.cancel()
            }
        } onCancel: {
            nw.cancel()
        }
    }

    // MARK: - Remote (-R)

    /// A remote forward lives only on its transport. The task
    /// self-heals: when the connection drops underneath it, it backs
    /// off and re-registers on the fresh transport — reconnects restore
    /// the rule without any outside kick. Each incoming forwarded-tcpip
    /// channel is piped to a fresh local TCP connection for the target.
    private func startRemote(rule: PortForward, entryGen: Int) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            let attempts = AttemptCounter()
            let targetHost = rule.targetHost
            let targetPort = rule.targetPort
            while !Task.isCancelled {
                do {
                    let client = try await connection.ensureConnected()
                    try Task.checkCancellation()
                    // Bind on the server's loopback — `ssh -R` defaults
                    // to loopback too; wildcard would expose the port
                    // network-wide.
                    try await client.withRemotePortForward(
                        host: "127.0.0.1",
                        port: rule.listenPort,
                        onOpen: { [weak self] _ in
                            await attempts.reset()
                            await self?.setRuntime(rule.id, .ready, entryGen: entryGen)
                        },
                        handleChannel: { channel, _ in
                            NIOPipeHandler.connect(
                                forwarded: channel,
                                targetHost: targetHost,
                                targetPort: targetPort
                            )
                        }
                    )
                } catch is CancellationError {
                    break
                } catch {
                    guard !Task.isCancelled else { break }
                    let attempt = await attempts.next()
                    self.setRuntime(rule.id, .failed("Remote forward failed"), entryGen: entryGen)
                    guard attempt < Self.maxRemoteRetries else { return }
                    try? await Task.sleep(for: Self.remoteBackoff(attempt))
                }
            }
            self.setRuntime(rule.id, .stopped, entryGen: entryGen)
        }
    }

    /// 2s, 4s, 8s… capped at 30s with jitter — reconnect storms on a
    /// flapping uplink shouldn't all retry in the same second.
    private static func remoteBackoff(_ attempt: Int) -> Duration {
        let seconds = min(30.0, pow(2.0, Double(attempt)))
        let jitter = Double.random(in: 0 ..< 0.5)
        return .milliseconds(Int((seconds + jitter) * 1000))
    }

    // MARK: - SOCKS5 (-D)

    /// Concurrency-capped handshake: greeting, channel open and reply
    /// all carry a deadline, and bridging stays gated until the reply
    /// has actually been written — the client never sees target bytes
    /// before its SOCKS reply, and request-piggybacked payload is
    /// forwarded first rather than dropped with the reader.
    private func handleSOCKS(_ nw: NWConnection, rule: PortForward) async {
        guard socksInFlight < Self.maxSOCKSHandshakes else {
            nw.cancel()
            return
        }
        socksInFlight += 1
        defer { socksInFlight -= 1 }
        let connID = trackAccepted(nw, ruleID: rule.id)
        nw.start(queue: DispatchQueue(label: "socks-conn"))
        await withTaskCancellationHandler {
            defer { forgetAccepted(connID) }
            var negotiated = false
            var failureRep: UInt8 = 0x01
            do {
                guard let (request, surplus) = try await withTimeout(Self.handshakeTimeout, {
                    try await Socks5.negotiate(on: nw)
                }) else {
                    nw.cancel()
                    return
                }
                negotiated = true
                failureRep = 0x01   // transport/SSH-level failure
                let client = try await withTimeout(Self.handshakeTimeout) {
                    try await connection.ensureConnected()
                }
                let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                let bridge = NIOToNWBridge(nw: nw, gated: true) { [weak self] in
                    Task { @MainActor in self?.forgetAccepted(connID) }
                }
                failureRep = 0x05   // target refused the channel
                let channel = try await withTimeout(Self.handshakeTimeout) {
                    try await client.createDirectTCPIPChannel(
                        using: SSHChannelType.DirectTCPIP(
                            targetHost: request.host,
                            targetPort: request.port,
                            originatorAddress: origin
                        )
                    ) { channel in
                        channel.pipeline.addHandler(bridge)
                    }
                }
                try await withTimeout(Self.handshakeTimeout) {
                    try await Socks5.sendReply(on: nw, rep: 0x00)
                    try await channel.eventLoop.submit {
                        bridge.begin(surplus: surplus, on: channel)
                    }.get()
                }
                try await channel.closeFuture.get()
            } catch {
                if negotiated {
                    try? await Socks5.sendReply(on: nw, rep: failureRep)
                }
                nw.cancel()
            }
        } onCancel: {
            nw.cancel()
        }
    }

    /// Real deadline, same shape as SSHConnection.withTimeout: a task
    /// group would await the losing child at scope exit and silently
    /// void the deadline, so the race happens on a boxed continuation —
    /// the loser is abandoned, and the work task is cancelled.
    private func withTimeout<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let box = NIOLockedValueBox<CheckedContinuation<T, Error>?>(nil)
        let workTask = Task<T, Error> { try await work() }
        defer { workTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.withLockedValue { $0 = cont }
                Task {
                    let result = await workTask.result
                    box.withLockedValue {
                        $0?.resume(with: result)
                        $0 = nil
                    }
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    box.withLockedValue {
                        $0?.resume(throwing: CancellationError())
                        $0 = nil
                    }
                }
            }
        } onCancel: {
            box.withLockedValue {
                $0?.resume(throwing: CancellationError())
                $0 = nil
            }
            workTask.cancel()
        }
    }
}

/// Bidirectional NIO↔NIO pipe for -R forwarding: a forwarded-tcpip
/// channel on one side, a local TCP channel to the target on the other.
/// Reads are paced — a side only reads while its partner is writable —
/// and EOF propagates as a half-close so a finished upload still gets
/// its response. Mutable state lives in a locked box for the same
/// reason as `NIOToNWBridge`.
private final class NIOPipeHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = NIOAny

    private struct State {
        var context: ChannelHandlerContext?
        var partner: NIOPipeHandler?
        var pendingRead = false
    }

    private let state = NIOLockedValueBox(State())

    private static func matchedPair() -> (NIOPipeHandler, NIOPipeHandler) {
        let a = NIOPipeHandler()
        let b = NIOPipeHandler()
        a.state.withLockedValue { $0.partner = b }
        b.state.withLockedValue { $0.partner = a }
        return (a, b)
    }

    /// Connects `forwarded` to `targetHost:targetPort` over a local TCP
    /// channel sharing its event loop, then plumbs both directions.
    /// The returned future fails when the target is unreachable, so the
    /// caller sees a refused forward rather than a silently dead one.
    static func connect(forwarded: Channel, targetHost: String, targetPort: Int) -> EventLoopFuture<Void> {
        ClientBootstrap(group: forwarded.eventLoop)
            .connect(host: targetHost, port: targetPort)
            .flatMap { local in
                let (a, b) = matchedPair()
                return forwarded.pipeline.addHandler(a).flatMap {
                    local.pipeline.addHandler(b)
                }
            }
    }

    private func partner() -> NIOPipeHandler? {
        state.withLockedValue { $0.partner }
    }

    // MARK: - Inbound → partner

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner()?.deliver(data)
    }

    /// `data` is written through immediately — per-chunk writeAndFlush
    /// keeps ordering exact and latency minimal on a same-loop pair.
    private func deliver(_ data: NIOAny) {
        let ctx = state.withLockedValue { $0.context }
        ctx?.writeAndFlush(data, promise: nil)
    }

    // MARK: - Paced reads

    func read(context: ChannelHandlerContext) {
        // Locks are taken one at a time, never nested — the partner's
        // box is only touched after this handler's is released.
        let writable = partner()?.isWritable ?? false
        if writable {
            context.read()
        } else {
            state.withLockedValue { $0.pendingRead = true }
        }
    }

    private var isWritable: Bool {
        state.withLockedValue { $0.context?.channel.isWritable ?? false }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner()?.resumePendingRead()
        }
        context.fireChannelWritabilityChanged()
    }

    private func resumePendingRead() {
        let ctx = state.withLockedValue { s -> ChannelHandlerContext? in
            guard s.pendingRead else { return nil }
            s.pendingRead = false
            return s.context
        }
        ctx?.read()
    }

    // MARK: - Lifecycle

    func handlerAdded(context: ChannelHandlerContext) {
        state.withLockedValue { $0.context = context }
        // Paced reads only — the pipe owns read() from now on.
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { [weak channel = context.channel] _ in
            channel?.read()
        }
        if context.channel.isWritable {
            partner()?.resumePendingRead()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        state.withLockedValue { s in
            s.context = nil
            s.partner = nil
        }
    }

    /// Partner reads EOF → only our output ends. The partner's own
    /// input side keeps flowing until it EOFs or dies too.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed {
            partner()?.writeEOF()
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    private func writeEOF() {
        let ctx = state.withLockedValue { $0.context }
        ctx?.close(mode: .output, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner()?.closeFull()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner()?.closeFull()
        context.close(promise: nil)
    }

    private func closeFull() {
        let ctx = state.withLockedValue { $0.context }
        ctx?.close(promise: nil)
    }
}

/// Retry counter shared between the self-healing task and the onOpen
/// callback — var captures can't cross the @Sendable boundary.
private actor AttemptCounter {
    private(set) var value = 0
    func next() -> Int {
        value += 1
        return value
    }
    func reset() {
        value = 0
    }
}

/// Minimal SOCKS5 server-side handshake (no-auth, CONNECT only).
enum Socks5 {
    struct Request: Equatable {
        let host: String
        let port: Int
    }

    /// Pure parse of "address + big-endian port" by ATYP byte — shared
    /// by the buffered reader and unit tests. `payload` is the bytes
    /// after ATYP (for domains it includes the leading length byte).
    static func parseRequest(atyp: UInt8, payload: Data) -> Request? {
        switch atyp {
        case 0x01: // IPv4
            guard payload.count == 6 else { return nil }
            let host = payload.prefix(4).map(String.init).joined(separator: ".")
            return make(host: host, portBytes: payload.suffix(2))
        case 0x03: // domain
            guard payload.count >= 2 else { return nil }
            let len = Int(payload[0])
            guard len > 0, payload.count == len + 3 else { return nil }
            let host = String(data: payload.dropFirst().prefix(len), encoding: .utf8) ?? ""
            return make(host: host, portBytes: payload.suffix(2))
        case 0x04: // IPv6
            guard payload.count == 18 else { return nil }
            var addr = in6_addr()
            _ = withUnsafeMutableBytes(of: &addr) { ptr in
                ptr.copyBytes(from: payload.prefix(16))
            }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var copy = addr
            let host = inet_ntop(AF_INET6, &copy, &buf, socklen_t(INET6_ADDRSTRLEN)).map { String(cString: $0) } ?? ""
            return make(host: host, portBytes: payload.suffix(2))
        default:
            return nil
        }
    }

    private static func make(host: String, portBytes: Data.SubSequence) -> Request? {
        let p = Data(portBytes)
        guard !host.isEmpty, p.count == 2 else { return nil }
        return Request(host: host, port: Int(p[0]) << 8 | Int(p[1]))
    }

    /// Buffered reader: a single NW receive can return greeting + request
    /// in one datagram — surplus bytes must be kept for the next field.
    /// Whatever remains after the request is payload the client already
    /// sent to the target; it is returned, not dropped.
    final class BufferedReader {
        private let nw: NWConnection
        private var buffer = Data()

        /// Bytes read past the parsed fields — early payload that must
        /// be forwarded into the SSH channel once bridging opens.
        var surplus: Data { buffer }

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

    /// Negotiates method + CONNECT request. Returns the target and the
    /// bytes that arrived piggybacked on the request, or nil once the
    /// proper reject reply has been sent — callers only ever close.
    static func negotiate(on nw: NWConnection) async throws -> (request: Request, surplus: Data)? {
        let reader = BufferedReader(on: nw)
        let greeting = try await reader.read(2)
        guard greeting[0] == 0x05 else { return nil }
        let methods = try await reader.read(Int(greeting[1]))
        guard methods.contains(0x00) else {
            // "No acceptable methods" — the only reply a greeting gets.
            try? await sendRaw(on: nw, Data([0x05, 0xFF]))
            return nil
        }
        try await sendRaw(on: nw, Data([0x05, 0x00]))

        let header = try await reader.read(4)
        guard header[0] == 0x05 else { return nil }
        guard header[1] == 0x01 else {
            // CMD: only CONNECT is supported — 0x07, not a generic fail.
            try? await sendReply(on: nw, rep: 0x07)
            return nil
        }
        guard header[2] == 0x00 else {
            // RSV must be zero — the request is malformed.
            try? await sendReply(on: nw, rep: 0x01)
            return nil
        }

        let request: Request?
        var badAddressType = false
        switch header[3] {
        case 0x01: // IPv4
            request = Self.parseRequest(atyp: 0x01, payload: try await reader.read(6))
        case 0x03: // domain
            let len = Int(try await reader.read(1)[0])
            guard len > 0 else {
                try? await sendReply(on: nw, rep: 0x01)
                return nil
            }
            var payload = Data([UInt8(len)])
            payload.append(try await reader.read(len + 2))
            request = Self.parseRequest(atyp: 0x03, payload: payload)
        case 0x04: // IPv6
            request = Self.parseRequest(atyp: 0x04, payload: try await reader.read(18))
        default:
            request = nil
            badAddressType = true
        }
        guard let request else {
            // 0x08 = address type not supported, 0x01 = malformed body.
            try? await sendReply(on: nw, rep: badAddressType ? 0x08 : 0x01)
            return nil
        }
        return (request, reader.surplus)
    }

    /// Full CONNECT reply — awaited so the wire order (reply before
    /// proxied bytes) is guaranteed before bridging starts.
    static func sendReply(on nw: NWConnection, rep: UInt8) async throws {
        try await sendRaw(on: nw, Data([0x05, rep, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
    }

    private static func sendRaw(on nw: NWConnection, _ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nw.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }
}
