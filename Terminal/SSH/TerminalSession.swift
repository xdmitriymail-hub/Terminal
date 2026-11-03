import Foundation
import SwiftUI
import UIKit
import Citadel
import NIO

/// One terminal tab: PTY lifecycle, output routing to the terminal view,
/// transparent reconnect and tmux reattach.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case connecting, online, reconnecting, offline, failed(String)
    }

    /// Why the shell channel ended — drives whether auto-reconnect may
    /// fire. A normal remote `exit` must never restart the session.
    private enum CloseReason {
        case remoteExit, transportLost, userClosed
    }

    let id = UUID()
    /// @Published so title/rows follow an edited profile in place —
    /// the next reconnect then dials the new endpoint too.
    @Published private(set) var profile: ServerProfile
    private(set) var connection: SSHConnection
    private let settings: SettingsStore
    weak var engine: SessionEngine?

    @Published private(set) var state: State = .connecting {
        didSet {
            // The engine republishes so `engine`-level observers
            // (keepalive activity, host rows) see flips that happen
            // inside a session — the array itself only emits on
            // add/remove.
            if oldValue != state { engine?.sessionActivityDidChange() }
        }
    }
    @Published var title: String

    private var shell: ShellChannel?
    private var consumeTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    /// Chained write+resize queue — bare Tasks can be scheduled out of
    /// order, reordering typed input on the wire. This is the single
    /// writer path for everything the PTY sends.
    private var sendChain: Task<Void, Never>?
    private var cols = 80
    private var rows = 24
    private var hadLiveSession = false
    private var isTerminated = false
    /// Bumped per connect attempt; every async result is gated on it so
    /// a stale/cancelled attempt can never publish into the current one.
    private var connectGeneration = 0
    private var lastCloseReason: CloseReason = .userClosed
    /// Auto-reconnect backoff state — cancellable, capped.
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    /// Budget exhausted — auto paths stop retrying until the user
    /// explicitly reconnects; otherwise a dead host gets hammered
    /// with handshakes and alert spam forever.
    private var retryBudgetSpent = false
    /// tmux attach was issued on the live channel — terminate can then
    /// retire the server-side session instead of leaking `term-*`.
    private var tmuxAttached = false
    /// Set when auth itself was declined (Face ID cancelled, keychain
    /// prompt denied) — an auth gate, not transport death: auto-retry
    /// never fires on it, but an explicit reconnect() recovers cleanly.
    private var authGated = false
    private static let maxRetryAttempts = 5
    /// Set after the user consents once — OSC 52 writes are then allowed
    /// for the rest of this session's life.
    var clipboardAllowed = false
    private var clipboardAsked = false

    /// Terminal view attaches here: raw output bytes to render.
    /// Title/bell go through the SwiftTerm delegate directly.
    var onOutput: (@MainActor (ArraySlice<UInt8>) -> Void)?

    /// Sticky Ctrl/Alt — owned here so the state survives accessory-bar
    /// rebuilds and SwiftUI re-instantiating its views.
    let modifiers = ModifierState()

    /// Output produced before a view attaches must not be dropped —
    /// it's buffered and flushed on attach (bounded, tail kept).
    private var pendingOutput = Data()
    private static let maxPendingOutput = 512 * 1024
    /// Chunks bound for the renderer, coalesced into one feed per frame
    /// window instead of one feed call per SSH packet.
    private var feedBuffer = Data()
    private var feedScheduled = false
    /// Per flush: at most this many bytes go into feed(), so a flood of
    /// output can't monopolize the main thread — the rest lands next
    /// frame. Nothing is ever dropped.
    private static let maxBytesPerFlush = 256 * 1024
    private static let flushInterval: Duration = .milliseconds(8)

    /// The view that currently owns the output handler — a second
    /// surface may briefly attach (a pushed sheet) and must not let
    /// its detach silence the real workspace renderer.
    private var outputOwner: ObjectIdentifier?
    /// Bumped on detach so views observing this session re-evaluate
    /// and the visible surface re-claims output — otherwise a
    /// dismissed sheet would leave the workspace terminal frozen.
    @Published private(set) var outputEpoch = 0

    func isOutputOwner(_ owner: AnyObject) -> Bool {
        outputOwner == ObjectIdentifier(owner)
    }

    /// Attach the renderer: installs the handler and replays anything
    /// that arrived while no view was bound.
    func attachOutput(owner: AnyObject, _ handler: @escaping @MainActor (ArraySlice<UInt8>) -> Void) {
        outputOwner = ObjectIdentifier(owner)
        onOutput = handler
        guard !pendingOutput.isEmpty else { return }
        feedBuffer.append(pendingOutput)
        pendingOutput.removeAll(keepingCapacity: true)
        scheduleFlush()
    }

    func detachOutput(owner: AnyObject) {
        guard outputOwner == ObjectIdentifier(owner) else { return }
        outputOwner = nil
        onOutput = nil
        outputEpoch += 1
        // Bytes already coalesced for the next frame are *older* than
        // whatever lands in pendingOutput next — merge them in front,
        // not behind, so the renderer never sees reordered output.
        if !feedBuffer.isEmpty {
            var merged = feedBuffer
            merged.append(pendingOutput)
            pendingOutput = merged
            feedBuffer.removeAll(keepingCapacity: true)
            trimPendingOutput()
        }
    }

    /// Bytes of our own internal commands still awaiting their PTY
    /// echo — a queue, one entry per silent send, so a chunk carrying
    /// the first echo plus unrelated bytes can't leak the command:
    /// matched bytes are excised, everything else passes through.
    private var pendingEchoes: [Data] = []
    private var echoDeadline = Date.distantPast

    /// Queues output for the next frame batch; with no view attached it
    /// lands in the bounded tail buffer instead. Internal-command echo
    /// is stripped first — prompt/MOTD bytes around it pass through
    /// untouched, so real output is never lost.
    private func deliverOutput(_ data: Data) {
        var data = data
        if !pendingEchoes.isEmpty {
            if Date() > echoDeadline { pendingEchoes.removeAll() }
            while !pendingEchoes.isEmpty, let echo = pendingEchoes.first {
                if let range = data.range(of: echo) {
                    // Whole echo in one chunk — excise just it and try
                    // the next expectation against what's left.
                    data.replaceSubrange(range, with: [])
                    pendingEchoes.removeFirst()
                    continue
                }
                // Echo hasn't arrived yet (motd/prompt pass first), or
                // it is split at this chunk's tail: real bytes flow
                // through, the held tail continues matching the next
                // chunk. The expectation only expires on the deadline.
                let maxTail = min(data.count, echo.count - 1)
                var tail = maxTail
                while tail > 0 {
                    if data.suffix(tail) == echo.prefix(tail) { break }
                    tail -= 1
                }
                if tail > 0 {
                    data.removeLast(tail)
                    pendingEchoes[0].removeFirst(tail)
                }
                break
            }
            guard !data.isEmpty else { return }
        }
        if onOutput != nil {
            feedBuffer.append(data)
            scheduleFlush()
        } else {
            pendingOutput.append(data)
            trimPendingOutput()
        }
    }

    private func scheduleFlush() {
        guard !feedScheduled else { return }
        feedScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            self?.pumpOutput()
        }
    }

    /// Drains the feed buffer in per-frame batches under a byte *and*
    /// time budget — the renderer gets a few large feeds rather than an
    /// unbounded flood of small ones, and never mid-queue truncation.
    private func pumpOutput() {
        feedScheduled = false
        guard let onOutput else {
            // Detached mid-flight: buffered bytes belong in the pending
            // tail, not the void — nothing is dropped on detach either.
            if !feedBuffer.isEmpty {
                pendingOutput.append(feedBuffer)
                feedBuffer.removeAll(keepingCapacity: true)
                trimPendingOutput()
            }
            return
        }
        guard !feedBuffer.isEmpty else { return }
        let out = feedBuffer
        feedBuffer = Data()
        feedBuffer.reserveCapacity(64 * 1024)
        let deadline = ContinuousClock.now + .milliseconds(8)
        var offset = out.startIndex
        while offset < out.endIndex {
            let end = out.index(offset, offsetBy: min(Self.maxBytesPerFlush, out.count - offset))
            onOutput(Array(out[offset..<end])[...])
            offset = end
            if offset < out.endIndex, ContinuousClock.now >= deadline {
                // Budget spent for this frame — prepend the remainder
                // ahead of anything that arrives next and continue on
                // the next tick. Order is preserved, bytes are kept.
                var remainder = Data(out[offset...])
                remainder.append(feedBuffer)
                feedBuffer = remainder
                scheduleFlush()
                return
            }
        }
    }

    /// Over-cap tail must start on a sequence boundary: prefer the next
    /// ESC (a full escape sequence survives), else the next UTF-8 lead
    /// byte, so the renderer never wakes up mid-CSI or mid-character.
    private func trimPendingOutput() {
        let overflow = pendingOutput.count - Self.maxPendingOutput
        guard overflow > 0 else { return }
        var cut = pendingOutput.index(pendingOutput.startIndex, offsetBy: overflow)
        let limit = pendingOutput.index(cut, offsetBy: min(4096, pendingOutput.count - overflow))
        // Preferred boundary: the next escape sequence start.
        var i = cut
        var found = false
        while i < limit {
            if pendingOutput[i] == 0x1B { cut = i; found = true; break }
            i = pendingOutput.index(after: i)
        }
        if !found {
            // Fallback: first byte that can start a UTF-8 scalar —
            // continuation bytes (10xx xxxx) are skipped over.
            cut = pendingOutput.index(pendingOutput.startIndex, offsetBy: overflow)
            while cut < pendingOutput.endIndex,
                  pendingOutput[cut] & 0xC0 == 0x80 {
                cut = pendingOutput.index(after: cut)
            }
        }
        pendingOutput = Data(pendingOutput[cut...])
    }

    /// Engine-driven: this tab wants a reconnect when its session died
    /// for transport reasons (or failed), including a tab sitting in a
    /// backoff — a foreground/path trigger should fire that wait now.
    /// A remote `exit` — offline by choice — is never auto-restarted.
    var wantsReconnect: Bool {
        hadLiveSession && !isTerminated && !retryBudgetSpent
            && ((state.isFailed && !authGated)
                || (state == .reconnecting && retryTask != nil)
                || (state == .offline && lastCloseReason == .transportLost))
    }

    /// This tab is doing network work — the pooled connection behind it
    /// earns health probes; idle, dead or failed tabs re-handshake
    /// lazily instead of running an exec every 25s.
    var isLiveConsumer: Bool {
        !isTerminated && (state == .online || state == .connecting || state == .reconnecting)
    }

    /// Remote `exit` ended the shell — "session ended", distinct from
    /// a dropped link, for badge/label text. Manual reconnect still
    /// works; the tmux reattach then resumes the server-side session.
    var endedRemotely: Bool {
        state == .offline && lastCloseReason == .remoteExit
    }

    init(profile: ServerProfile, connection: SSHConnection, settings: SettingsStore) {
        self.profile = profile
        self.connection = connection
        self.settings = settings
        self.title = profile.displayName
    }

    func start(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        runConnect()
    }

    /// One owned task per connect attempt — superseded attempts are
    /// cancelled so a slow old handshake can't resurrect the tab. The
    /// generation counter is what makes "cancelled" observable: any
    /// async path holding an old generation simply doesn't publish.
    private func runConnect() {
        connectGeneration += 1
        authGated = false
        let gen = connectGeneration
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.connect(gen: gen)
        }
    }

    private func connect(gen: Int) async {
        guard !isTerminated else { return }
        state = hadLiveSession ? .reconnecting : .connecting
        // A pending password ask retires the moment the retry leaves
        // .failed — cleared here, not by the prompt itself, so pending
        // watchers see a live reconnect instead of an abandoned one.
        engine?.clearPasswordPrompt(for: self)
        do {
            let shell = try await connection.openShell(cols: cols, rows: rows)
            guard !isTerminated, !Task.isCancelled, gen == connectGeneration else {
                await shell.close()
                return
            }
            // Replace the previous shell atomically: the old channel is
            // closed, stale queued input is dropped and sticky modifiers
            // are cleared — nothing from the dead attempt leaks into
            // the new PTY.
            let old = self.shell
            self.shell = shell
            resetForNewShell()
            if let old {
                Task { await old.close() }
            }
            hadLiveSession = true
            retryAttempt = 0
            retryBudgetSpent = false
            engine?.clearPasswordPrompt(for: self)
            // One exec round-trip learns tmux + OS — before the tab
            // goes live and before the attach is written, so nothing
            // typed meanwhile glues onto our wiring.
            let probe = await engine?.probeHost(self)
            guard !isTerminated, !Task.isCancelled, gen == connectGeneration else {
                await shell.close()
                return
            }
            consume(shell, gen: gen)
            // The new channel gets the current size even if the PTY
            // request already carried it — resizes that failed on the
            // dead channel are replayed here.
            enqueueResize()
            sendShellOverride(gen: gen)
            attachTmux(gen: gen, available: probe?.hasTmux == true)
            reachedOnline = true
            state = .online
        } catch {
            handleConnectFailure(error, gen: gen)
        }
    }

    /// First successful online — the workspace only shows tabs that
    /// actually reached a shell; a still-connecting attempt keeps the
    /// server list (and its icon ring) on screen instead of flashing
    /// an empty terminal.
    private(set) var reachedOnline = false

    /// Input queue, consume loop and sticky modifiers belong to the
    /// shell they were captured against — a replacement starts clean.
    /// Every fresh shell — manual reconnect or auto-retry alike — runs
    /// the remote probe again; the tmux flag itself is NOT reset here:
    /// the server-side `term-*` session survives a transport drop and
    /// terminating the tab still has to retire it.
    private func resetForNewShell() {
        sendChain?.cancel()
        sendChain = nil
        consumeTask?.cancel()
        consumeTask = nil
        modifiers.reset()
    }

    /// A failed attempt only publishes when it is still the current
    /// one: a cancelled or superseded connect can never overwrite a
    /// newer state, and its error alert never fires.
    private func handleConnectFailure(_ error: Error, gen: Int) {
        guard !isTerminated, gen == connectGeneration, !Task.isCancelled else { return }
        // A denied or cancelled biometric prompt gates auth — it is
        // not a transport failure: no retry budget is spent and the
        // auto-retry loop never fires on it. The failed state stays
        // resumable through an explicit reconnect.
        if case KeyVaultError.biometricDenied = error {
            authGated = true
            state = .failed(String(localized: "Authentication cancelled"))
            return
        }
        // Missing or rejected password asks again — the prompt queues
        // BEFORE the failed state publishes, so UI watching the state
        // sees the outstanding ask and doesn't tear the session down
        // underneath the prompt.
        let authRejected = (error as? SSHClientError) == .allAuthenticationOptionsFailed
        if case .password = profile.auth,
           case KeyVaultError.keyMaterialMissing = error {
            engine?.authNeeded(self)
            state = .failed(Self.describe(error))
            return
        }
        if authRejected, case .password = profile.auth {
            // The stored password was tried and refused — keeping it
            // would make every retry fail identically while the prompt
            // pretends to be fresh. Drop it so the ask is genuine.
            _ = Keychain.delete(tag: "password.\(profile.id.uuidString)")
            engine?.authNeeded(self)
            state = .failed(String(localized: "Access denied"))
            return
        }
        if authRejected {
            let alreadyFailed = state.isFailed
            state = .failed(String(localized: "Access denied"))
            if !alreadyFailed { engine?.reportError(String(localized: "Access denied")) }
            return
        }
        // Mid-retry-cycle failure: keep cycling quietly while attempts
        // remain; alert once the budget is spent.
        if hadLiveSession, lastCloseReason == .transportLost,
           settings.settings.autoReconnect, retryAttempt < Self.maxRetryAttempts {
            scheduleRetry()
            return
        }
        // Failed-states dedupe their own alert — a retry cycle that
        // keeps landing in .failed doesn't re-alert every round.
        let alreadyFailed = state.isFailed
        state = .failed(Self.describe(error))
        if !alreadyFailed {
            engine?.reportError(Self.describe(error))
        }
    }

    private func consume(_ shell: ShellChannel, gen: Int) {
        consumeTask = Task { [weak self] in
            while let event = await shell.nextEvent() {
                if Task.isCancelled { return }
                switch event {
                case .output(let data):
                    self?.deliverOutput(data)
                case .closed(let error):
                    await self?.shellClosed(shell, error: error, gen: gen)
                    return
                }
            }
            // Queue drained without a .closed event — still a close.
            await self?.shellClosed(shell, error: nil, gen: gen)
        }
    }

    /// The channel ended: distinguish a remote `exit` from transport
    /// loss — only the latter may auto-reconnect. Events from a shell
    /// that is no longer current are dropped, so a stale close can't
    /// write offline over a fresh online.
    private func shellClosed(_ shell: ShellChannel, error: Error?, gen: Int) async {
        guard !isTerminated, gen == connectGeneration, shell === self.shell else { return }
        self.shell = nil
        if error != nil {
            lastCloseReason = .transportLost
        } else {
            // Clean EOF: the remote shell exited, or the transport died
            // and took the channel silently — the liveness check splits
            // the two. Only the dead-transport case may retry.
            lastCloseReason = await connection.isConnected ? .remoteExit : .transportLost
        }
        switch lastCloseReason {
        case .remoteExit:
            // The remote shell ended (exit/logout): the tab's job is
            // done — retire it rather than freeze a dead screen.
            state = .offline
            engine?.closeSession(self)
        case .userClosed:
            state = .offline
        case .transportLost:
            scheduleRetry()
        }
    }

    // MARK: - Auto-reconnect

    /// Cancellable retry with capped exponential backoff + jitter. A
    /// dead transport on a stable network no longer stays dead, and a
    /// remote `exit` never reaches this path at all.
    private func scheduleRetry() {
        guard !isTerminated, settings.settings.autoReconnect else {
            state = .offline
            return
        }
        guard retryAttempt < Self.maxRetryAttempts else {
            retryBudgetSpent = true
            let alreadyFailed = state.isFailed
            state = .failed(String(localized: "Connection lost"))
            if !alreadyFailed {
                engine?.reportError(String(localized: "Couldn't reconnect"))
            }
            return
        }
        retryTask?.cancel()
        let attempt = retryAttempt
        let gen = connectGeneration
        state = .reconnecting
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.backoff(attempt: attempt))
            guard !Task.isCancelled else { return }
            self?.fireRetry(gen: gen)
        }
    }

    /// 1s, 2s, 4s, 8s, 16s + up to 500ms of jitter — hammering a
    /// recovering server in lock-step helps no one.
    private static func backoff(attempt: Int) -> Duration {
        let seconds = min(16.0, pow(2.0, Double(attempt)))
        let jitter = Double.random(in: 0 ..< 0.5)
        return .milliseconds(Int((seconds + jitter) * 1000))
    }

    private func fireRetry(gen: Int) {
        guard !isTerminated, gen == connectGeneration else { return }
        retryAttempt += 1
        runConnect()
    }

    /// The transport dropped under a healthy-looking session — the
    /// pooled connection noticed before the channel did.
    func noteTransportLost() {
        guard state == .online, !isTerminated else { return }
        lastCloseReason = .transportLost
        scheduleRetry()
    }

    /// Each tab keeps its own tmux session (named per tab), so parallel
    /// tabs never fight over one attach. The command is a plain `;`
    /// chain — no `||` after attach, or a normal `exit` would respawn
    /// a fresh tmux forever. `status off` lands before the attach, so
    /// the green status bar never flashes into view.
    private func attachTmux(gen: Int, available: Bool) {
        guard profile.autoTmux, settings.settings.autoTmux, available,
              !isTerminated, gen == connectGeneration, !Task.isCancelled else { return }
        let name = "term-\(id.uuidString)"
        tmuxAttached = true
        // `exec` before attach: when the tmux session ends (exit from
        // the last pane) there is no login shell left to fall back to —
        // the channel closes, and the tab retires into the server list
        // instead of reviving a bare prompt behind the user's back.
        sendSilently("tmux new-session -d -s \(Self.shQuote(name)) 2>/dev/null; tmux set-option -t \(Self.shQuote(name)) status off; exec tmux attach -t \(Self.shQuote(name))\r")
    }

    /// What one exec round-trip learns about the remote. `hasTmux` is
    /// nil when the probe itself failed — a timed-out exec must not be
    /// cached as "no tmux" and orphan the server-side session forever.
    struct RemoteProbe: Sendable {
        var hasTmux: Bool?
        var osID: String?
        var osName: String?
    }

    /// Combined remote probe — tmux path, kernel, distro identity in a
    /// single exec. Marker letters keep the output parseable even when
    /// one probe prints nothing.
    func probeRemote() async -> RemoteProbe {
        let probe = "printf 'T>'; command -v tmux || true; printf 'K>'; uname -s; printf 'D>'; . /etc/os-release 2>/dev/null; printf '%s|%s' \"${ID:-}\" \"${PRETTY_NAME:-}\""
        guard let raw = try? await connection.execute(probe) else {
            return RemoteProbe()
        }
        func field(_ marker: String, until next: String?) -> String {
            guard let start = raw.range(of: marker) else { return "" }
            let tail = raw[start.upperBound...]
            let end = next.flatMap { tail.range(of: $0)?.lowerBound } ?? tail.endIndex
            return String(tail[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = RemoteProbe()
        out.hasTmux = !field("T>", until: "K>").isEmpty
        let kernel = field("K>", until: "D>").lowercased()
        guard !kernel.isEmpty else { return out }
        var id = kernel
        var name: String
        switch kernel {
        case "darwin": name = "macOS"
        case "freebsd": name = "FreeBSD"
        case "openbsd": name = "OpenBSD"
        case "netbsd": name = "NetBSD"
        case "linux": name = "Linux"
        default: name = kernel.capitalized
        }
        if kernel == "linux" {
            let distro = field("D>", until: nil).split(separator: "|", maxSplits: 1)
            if let d = distro.first, !d.isEmpty {
                id = String(d).lowercased()
                name = distro.count > 1 && !distro[1].isEmpty ? String(distro[1]) : d.capitalized
            }
        }
        out.osID = id
        out.osName = name
        return out
    }

    /// `exec` replaces the login shell with the configured override.
    /// Path AND every argument are POSIX-quoted individually — a field
    /// like `zsh -l` must reach the remote as exactly two arguments,
    /// never interpolated into shell metacharacters or re-splits.
    private func sendShellOverride(gen: Int) {
        let override = settings.settings.shellOverride.trimmingCharacters(in: .whitespaces)
        guard !override.isEmpty, gen == connectGeneration, !isTerminated else { return }
        let parts = Self.shellWords(override)
        guard !parts.isEmpty else { return }
        sendSilently("exec \(parts.map(Self.shQuote).joined(separator: " "))\r")
    }

    /// Whitespace-split into words — an override is "path plus flags",
    /// each token quoted separately downstream.
    private static func shellWords(_ command: String) -> [String] {
        command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// POSIX single-quote: the only metachar that survives is ' itself,
    /// which is closed, escaped and reopened.
    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Clipboard (OSC 52)

    /// Remote clipboard writes: gated by the setting, size-capped, and
    /// confirmed once per session — a hostile server must never reach
    /// the pasteboard silently.
    func clipboardWrite(_ data: Data) {
        guard settings.settings.remoteClipboard, data.count <= 512_000 else { return }
        if clipboardAllowed {
            UIPasteboard.general.setData(data, forPasteboardType: "public.utf8-plain-text")
            return
        }
        guard !clipboardAsked else { return }
        clipboardAsked = true
        engine?.onClipboardRequest?(self, data)
    }

    // MARK: - Input

    /// Raw write path — snippets, auto-commands and control bytes go
    /// through the single ordered send chain.
    func send(_ data: ArraySlice<UInt8>) {
        let previous = sendChain
        let shell = self.shell
        sendChain = Task { [weak shell] in
            _ = await previous?.value
            await shell?.send(Array(data))
        }
    }

    /// Text input: line endings normalize to CR — a PTY's Return is
    /// carriage return, and a bare LF is not how a terminal submits.
    func send(_ string: String) {
        send(Self.crNormalize([UInt8](string.utf8))[...])
    }

    /// Internal wiring (tmux attach, shell override): goes through the
    /// same ordered chain, but the PTY's echo of these bytes is queued
    /// for suppression — the terminal shows none of it.
    func sendSilently(_ string: String) {
        let bytes = Self.crNormalize([UInt8](string.utf8))
        var echo = Data()
        for b in bytes {
            echo.append(b)
            // A CR echoes back as CRLF on a cooked pty.
            if b == 0x0D { echo.append(0x0A) }
        }
        pendingEchoes.append(echo)
        echoDeadline = Date().addingTimeInterval(3)
        send(bytes[...])
    }

    /// Typed input: sticky Ctrl/Alt apply here, semantically — Ctrl is
    /// only meaningful on classic ASCII chords, so arbitrary UTF-8
    /// bytes are never control-masked into garbage codes.
    func sendUserInput(_ bytes: [UInt8]) {
        send(Self.crNormalize(applyStickyModifiers(to: bytes))[...])
    }

    private func applyStickyModifiers(to bytes: [UInt8]) -> [UInt8] {
        if modifiers.ctrl {
            defer { modifiers.reset() }
            guard bytes.count == 1, let byte = bytes.first,
                  let ctrl = Self.ctrlByte(for: byte) else {
                return bytes
            }
            return [ctrl]
        }
        if modifiers.alt {
            defer { modifiers.reset() }
            return [0x1B] + bytes
        }
        return bytes
    }

    /// The classic Ctrl chord set: @ A–Z [ \ ] ^ _, a–z, Space, ? and
    /// the xterm digit aliases. Everything else has no control meaning.
    private static func ctrlByte(for byte: UInt8) -> UInt8? {
        switch byte {
        case 0x20: return 0x00                    // Ctrl-Space = NUL
        case 0x3F: return 0x7F                    // Ctrl-? = DEL
        case 0x40...0x5F: return byte & 0x1F      // @, A–Z, [ \ ] ^ _
        case 0x61...0x7A: return byte & 0x1F      // a–z → ^A–^Z
        case 0x32: return 0x00                    // Ctrl-2 = NUL
        case 0x33...0x37: return byte - 0x18      // Ctrl-3..7 = ESC,FS,GS,RS,US
        case 0x38: return 0x7F                    // Ctrl-8 = DEL
        default: return nil
        }
    }

    /// CR is what a terminal sends for Return; CRLF collapses to a
    /// single CR so pasted text doesn't double-submit. Inside a
    /// bracketed paste (`ESC[200~`…`ESC[201~`) bytes pass through
    /// untouched — the mode exists precisely so the application reads
    /// the text literally, and rewriting LF to CR there prints ^M in
    /// every pasted line.
    static func crNormalize(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        var inPaste = false
        while i < bytes.count {
            let byte = bytes[i]
            // ESC [ 2 0 x ~ — the bracketed-paste envelope.
            if byte == 0x1B, i + 5 < bytes.count,
               bytes[i + 1] == 0x5B, bytes[i + 2] == 0x32,
               bytes[i + 3] == 0x30, bytes[i + 5] == 0x7E,
               bytes[i + 4] == 0x30 || bytes[i + 4] == 0x31 {
                inPaste = bytes[i + 4] == 0x30
                out.append(contentsOf: bytes[i...i + 5])
                i += 6
                continue
            }
            if inPaste {
                out.append(byte)
            } else if byte == 0x0D {
                out.append(0x0D)
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 1 }
            } else if byte == 0x0A {
                out.append(0x0D)
            } else {
                out.append(byte)
            }
            i += 1
        }
        return out
    }

    // MARK: - Resize

    /// Single writer path: the resize rides the same ordered chain as
    /// input, reads the *latest* size when it fires (bursts coalesce)
    /// and the channel sequence-guards anything still racing.
    func setSize(cols: Int, rows: Int) {
        let cols = max(1, cols), rows = max(1, rows)
        guard cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        enqueueResize()
    }

    private func enqueueResize() {
        let previous = sendChain
        let shell = self.shell
        sendChain = Task { [weak self, weak shell] in
            _ = await previous?.value
            guard let self else { return }
            await shell?.setSize(cols: self.cols, rows: self.rows)
        }
    }

    // MARK: - Reconnect

    /// Reconnecting a tab must not kill the transport other tabs and
    /// SFTP share — the pooled connection decides for itself whether
    /// the transport is dead and re-handshakes lazily.
    func reconnectIfNeeded() async {
        guard !isTerminated else { return }
        guard state != .connecting else { return }
        // A pending backoff counts as offline-ish: an explicit trigger
        // (network path restored, app foregrounded) fires it now.
        guard state == .offline || (state.isFailed && !authGated && !retryBudgetSpent) || (state == .reconnecting && retryTask != nil) else { return }
        retryTask?.cancel()
        retryTask = nil
        runConnect()
    }

    func reconnect() {
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        retryBudgetSpent = false
        runConnect()
    }

    func terminate() {
        // An in-flight handshake dies with the tab — but only this
        // consumer's wait is cancelled; the pooled connection keeps the
        // shared connect alive for siblings that still need it. A live
        // connection is shared, so it's left alone.
        isTerminated = true
        connectGeneration += 1
        connectTask?.cancel()
        connectTask = nil
        retryTask?.cancel()
        retryTask = nil
        sendChain?.cancel()
        sendChain = nil
        consumeTask?.cancel()
        consumeTask = nil
        if let shell {
            self.shell = nil
            if tmuxAttached {
                // Retire the server-side `term-*` session this tab
                // owned — closing the channel alone leaks it on the
                // host forever. Serial before the close: a dead
                // transport throws fast and close still runs.
                tmuxAttached = false
                let name = "term-\(id.uuidString)"
                Task {
                    try? await connection.execute("tmux kill-session -t \(Self.shQuote(name))")
                    await shell.close()
                }
            } else {
                Task { await shell.close() }
            }
        }
        engine?.sessionTerminated(self)
        state = .offline
    }

    /// The profile was edited under a live tab: identity follows the
    /// new record and the pooled transport is swapped, so the next
    /// channel dials the new host/port/user/key instead of the stale
    /// endpoint. The engine drops the old transport — its close event
    /// drives any reconnect through the usual path.
    func retarget(profile: ServerProfile, connection newConnection: SSHConnection) {
        self.profile = profile
        title = profile.displayName
        guard newConnection !== self.connection else { return }
        self.connection = newConnection
    }

    /// One short human phrase per failure class — never raw error text.
    static func describe(_ error: Error) -> String {
        switch error {
        case is UntrustedHostKey:
            return String(localized: "Couldn't verify this server")
        case KeyVaultError.biometricDenied:
            return String(localized: "Unlock cancelled")
        case KeyVaultError.keyMaterialMissing:
            return String(localized: "Password required")
        case is CancellationError:
            return String(localized: "Couldn't connect")
        case SSHClientError.allAuthenticationOptionsFailed:
            return String(localized: "Access denied")
        case SSHClientError.unsupportedPasswordAuthentication,
             SSHClientError.unsupportedPrivateKeyAuthentication,
             SSHClientError.unsupportedHostBasedAuthentication:
            return String(localized: "Sign-in method rejected")
        case SSHClientError.channelCreationFailed,
             CitadelError.channelCreationFailed, CitadelError.channelFailure:
            return String(localized: "Couldn't open a session")
        case is AuthenticationFailed:
            return String(localized: "Access denied")
        default:
            break
        }
        if let ioError = error as? IOError {
            switch ioError.errnoCode {
            case ECONNREFUSED:
                return String(localized: "Connection refused")
            case ETIMEDOUT:
                return String(localized: "Connection timed out")
            case ENETUNREACH, EHOSTUNREACH:
                return String(localized: "No route to host")
            case ECONNRESET, ECONNABORTED, EPIPE:
                return String(localized: "Connection lost")
            default:
                break
            }
        }
        if let channelError = error as? ChannelError {
            if case .connectTimeout = channelError {
                return String(localized: "Connection timed out")
            }
            return String(localized: "Connection lost")
        }
        if error is SocketAddressError.UnknownHost {
            return String(localized: "Couldn't resolve host")
        }
        return String(localized: "Couldn't connect")
    }
}

private extension TerminalSession.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
