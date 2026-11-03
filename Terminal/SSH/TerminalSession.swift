import Foundation
import SwiftUI
import UIKit
import Citadel

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
    let profile: ServerProfile
    private let connection: SSHConnection
    private let settings: SettingsStore
    weak var engine: SessionEngine?

    @Published private(set) var state: State = .connecting
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
    private var tmuxChecked = false
    private var isTerminated = false
    /// Bumped per connect attempt; every async result is gated on it so
    /// a stale/cancelled attempt can never publish into the current one.
    private var connectGeneration = 0
    private var lastCloseReason: CloseReason = .userClosed
    /// Auto-reconnect backoff state — cancellable, capped.
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
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

    /// Attach the renderer: installs the handler and replays anything
    /// that arrived while no view was bound.
    func attachOutput(_ handler: @escaping @MainActor (ArraySlice<UInt8>) -> Void) {
        onOutput = handler
        guard !pendingOutput.isEmpty else { return }
        feedBuffer.append(pendingOutput)
        pendingOutput.removeAll(keepingCapacity: true)
        scheduleFlush()
    }

    func detachOutput() {
        onOutput = nil
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
    /// echo — swallowed in deliverOutput so wiring like the tmux
    /// attach never surfaces on screen or in scrollback.
    private var pendingEcho = Data()
    private var echoDeadline = Date.distantPast

    /// Queues output for the next frame batch; with no view attached it
    /// lands in the bounded tail buffer instead. Internal-command echo
    /// is stripped first — anything not matching the pending echo falls
    /// through untouched, so real output is never lost.
    private func deliverOutput(_ data: Data) {
        var data = data
        if !pendingEcho.isEmpty {
            if Date() > echoDeadline { pendingEcho.removeAll() }
            if !pendingEcho.isEmpty {
                var dropped = 0
                while dropped < data.count, let expected = pendingEcho.first,
                      data[data.index(data.startIndex, offsetBy: dropped)] == expected {
                    pendingEcho.removeFirst()
                    dropped += 1
                }
                // A mismatch means the echo finished differently than
                // expected — drop the stale expectation, keep the bytes.
                if !pendingEcho.isEmpty, dropped < data.count { pendingEcho.removeAll() }
                data.removeFirst(dropped)
                guard !data.isEmpty else { return }
            }
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
        hadLiveSession && !isTerminated
            && ((state.isFailed && !authGated)
                || (state == .reconnecting && retryTask != nil)
                || (state == .offline && lastCloseReason == .transportLost))
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
            state = .online
            engine?.clearPasswordPrompt(for: self)
            consume(shell, gen: gen)
            // The new channel gets the current size even if the PTY
            // request already carried it — resizes that failed on the
            // dead channel are replayed here.
            enqueueResize()
            sendShellOverride(gen: gen)
            await reattachIfNeeded(gen: gen)
            // Row icon/label learn the real OS — once, off the hot path.
            if profile.osID == nil {
                Task { await engine?.learnOS(for: self) }
            }
        } catch {
            handleConnectFailure(error, gen: gen)
        }
    }

    /// Input queue, consume loop and sticky modifiers belong to the
    /// shell they were captured against — a replacement starts clean.
    /// The once-per-channel tmux check re-arms here too: every fresh
    /// shell — manual reconnect or auto-retry alike — gets its
    /// reattach, and the old `term-*` session is resumed, not leaked.
    private func resetForNewShell() {
        sendChain?.cancel()
        sendChain = nil
        consumeTask?.cancel()
        consumeTask = nil
        modifiers.reset()
        tmuxChecked = false
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
            state = .failed("Authentication cancelled")
            return
        }
        // Missing password isn't a failure worth an alert — ask the
        // user for it, then retry through the same session. The prompt
        // queues BEFORE the failed state publishes, so UI watching the
        // state sees the outstanding ask and doesn't tear the session
        // down underneath the prompt.
        if case KeyVaultError.keyMaterialMissing = error, case .password = profile.auth {
            engine?.authNeeded(self)
            state = .failed(Self.describe(error))
            return
        }
        // Mid-retry-cycle failure: keep cycling quietly while attempts
        // remain; alert once the budget is spent.
        if hadLiveSession, lastCloseReason == .transportLost,
           settings.settings.autoReconnect, retryAttempt < Self.maxRetryAttempts {
            scheduleRetry()
            return
        }
        state = .failed(Self.describe(error))
        engine?.reportError(Self.describe(error))
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
        case .remoteExit, .userClosed:
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
            state = .failed("Connection lost")
            engine?.reportError("Couldn't reconnect")
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
    /// tabs never fight over one attach. Detection is cached on the
    /// engine; the check itself re-runs after every reconnect.
    private func reattachIfNeeded(gen: Int) async {
        guard profile.autoTmux, settings.settings.autoTmux, !tmuxChecked,
              gen == connectGeneration else { return }
        tmuxChecked = true
        let available = await engine?.hasTmux(on: self) ?? false
        // No sleep-as-synchronization: the channel-open handshake was
        // already awaited inside openShell, and the generation check is
        // what keeps a stale attempt from typing into a new shell.
        guard available, !isTerminated, gen == connectGeneration, !Task.isCancelled else { return }
        let name = "term-\(id.uuidString)"
        // `;` escaped so the shell passes it to tmux verbatim — tmux
        // chains `set-option` onto the just-attached session, keeping
        // its green status bar out of the clean terminal view.
        sendSilently("tmux new-session -A -s \(Self.shQuote(name)) \\; set-option status off 2>/dev/null || tmux new-session -s \(Self.shQuote(name)) \\; set-option status off\r")
    }

    /// Probes the remote once per profile (cached on the engine) — exec
    /// channels are cheap, repeating `command -v` per tab is not.
    func detectTmux() async -> Bool {
        guard let path = try? await connection.execute("command -v tmux || true") else {
            return false
        }
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One-shot OS probe for the server-row icon/label: `uname -s`
    /// for the kernel, os-release for the distro identity. Fails
    /// silently — a missing OS never blocks the shell.
    func detectOS() async -> (id: String, name: String)? {
        let probe = "uname -s; . /etc/os-release 2>/dev/null; echo \"${ID:-} ${PRETTY_NAME:-}\""
        guard let raw = try? await connection.execute(probe) else { return nil }
        let lines = raw.split(separator: "\n").map(String.init)
        let kernel = (lines.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kernel.isEmpty else { return nil }
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
        if kernel == "linux", lines.count > 1 {
            let fields = lines[1].split(separator: " ", maxSplits: 1)
            if let distro = fields.first, !distro.isEmpty {
                id = String(distro).lowercased()
                if fields.count > 1, !fields[1].isEmpty {
                    name = String(fields[1])
                } else {
                    name = distro.capitalized
                }
            }
        }
        return (id, name)
    }

    /// `exec` replaces the login shell with the configured override.
    /// Path and arguments are separated and the path is POSIX-quoted —
    /// an override with spaces or metacharacters is never interpolated
    /// as shell program text.
    private func sendShellOverride(gen: Int) {
        let override = settings.settings.shellOverride.trimmingCharacters(in: .whitespaces)
        guard !override.isEmpty, gen == connectGeneration, !isTerminated else { return }
        let (path, args) = Self.splitPathAndArgs(override)
        guard !path.isEmpty else { return }
        let suffix = args.isEmpty ? "" : " \(args)"
        sendSilently("exec \(Self.shQuote(path))\(suffix)\r")
    }

    /// First whitespace run splits the executable path from its
    /// argument tail, which passes through verbatim.
    private static func splitPathAndArgs(_ command: String) -> (path: String, args: String) {
        guard let range = command.rangeOfCharacter(from: .whitespaces) else {
            return (command, "")
        }
        let path = String(command[command.startIndex..<range.lowerBound])
        let args = String(command[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (path, args)
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
        pendingEcho.append(echo)
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
    /// single CR so pasted text doesn't double-submit.
    static func crNormalize(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x0D {
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
        guard state == .offline || (state.isFailed && !authGated) || (state == .reconnecting && retryTask != nil) else { return }
        retryTask?.cancel()
        retryTask = nil
        runConnect()
    }

    func reconnect() {
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
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
            Task { await shell.close() }
        }
        engine?.sessionTerminated(self)
        state = .offline
    }

    /// One short human phrase per failure class — never raw error text.
    static func describe(_ error: Error) -> String {
        switch error {
        case is UntrustedHostKey:
            return "Couldn't verify this server"
        case is SSHClient.CommandFailed:
            return "Couldn't open a session"
        case KeyVaultError.biometricDenied:
            return "Unlock cancelled"
        case is CancellationError:
            return "Couldn't connect"
        default:
            // Surface the real reason — refused vs timed out vs auth —
            // instead of a generic banner that hides everything.
            let desc = error.localizedDescription
            return desc.isEmpty ? "Couldn't connect" : desc
        }
    }
}

private extension TerminalSession.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
