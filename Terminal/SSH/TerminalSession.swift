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
    /// Chained write queue — bare Tasks can be scheduled out of order,
    /// reordering typed input on the wire.
    private var sendChain: Task<Void, Never>?
    private var cols = 80
    private var rows = 24
    private var hadLiveSession = false
    private var tmuxChecked = false
    private var isTerminated = false
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

    /// Attach the renderer: installs the handler and replays anything
    /// that arrived while no view was bound.
    func attachOutput(_ handler: @escaping @MainActor (ArraySlice<UInt8>) -> Void) {
        onOutput = handler
        guard !pendingOutput.isEmpty else { return }
        let data = pendingOutput
        pendingOutput.removeAll(keepingCapacity: true)
        handler(Array(data)[...])
    }

    func detachOutput() {
        onOutput = nil
    }

    private func deliverOutput(_ data: Data) {
        if let onOutput {
            onOutput(ArraySlice(data))
        } else {
            pendingOutput.append(data)
            let overflow = pendingOutput.count - Self.maxPendingOutput
            if overflow > 0 {
                pendingOutput.removeFirst(overflow)
            }
        }
    }

    var wantsReconnect: Bool { hadLiveSession && state != .offline }

    init(profile: ServerProfile, connection: SSHConnection, settings: SettingsStore) {
        self.profile = profile
        self.connection = connection
        self.settings = settings
        self.title = profile.displayName
    }

    func start(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        runConnect()
    }

    /// One owned task per connect attempt — superseded attempts are
    /// cancelled so a slow old handshake can't resurrect the tab.
    private func runConnect() {
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.connect()
        }
    }

    private func connect() async {
        guard !isTerminated else { return }
        state = hadLiveSession ? .reconnecting : .connecting
        do {
            let shell = try await connection.openShell(cols: cols, rows: rows)
            guard !isTerminated, !Task.isCancelled else {
                await shell.close()
                return
            }
            self.shell = shell
            hadLiveSession = true
            state = .online
            consume(shell)
            // An explicit shell preference replaces the login shell.
            let shellPath = settings.settings.shellOverride.trimmingCharacters(in: .whitespaces)
            if !shellPath.isEmpty {
                send("exec \(shellPath)\n")
            }
            await reattachIfNeeded()
        } catch {
            guard !isTerminated else { return }
            state = .failed(Self.describe(error))
            // Missing password isn't a failure worth an alert — ask the
            // user for it, then retry through the same session.
            if case KeyVaultError.keyMaterialMissing = error, case .password = profile.auth {
                engine?.onAuthNeeded?(self)
            } else {
                engine?.reportError(Self.describe(error))
            }
        }
    }

    private func consume(_ shell: ShellChannel) {
        consumeTask?.cancel()
        consumeTask = Task { [weak self] in
            do {
                for try await event in shell.output {
                    guard let self else { return }
                    switch event {
                    case .output(let data):
                        await MainActor.run {
                            self.deliverOutput(data)
                        }
                    case .closed(let error):
                        await MainActor.run {
                            if let error {
                                self.state = .failed(Self.describe(error))
                            } else {
                                self.state = .offline
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self?.state = .failed(Self.describe(error))
                }
                return
            }
            // Stream ended without a .closed event (shouldn't happen,
            // but never leave a stale "online" state behind).
            await MainActor.run {
                if self?.state == .online || self?.state == .reconnecting {
                    self?.state = .offline
                }
            }
        }
    }

    /// Each tab keeps its own tmux session (named per tab), so parallel
    /// tabs never fight over one attach. Detection is cached on the
    /// engine; the check itself re-runs after every reconnect.
    private func reattachIfNeeded() async {
        guard profile.autoTmux, settings.settings.autoTmux, !tmuxChecked else { return }
        tmuxChecked = true
        let available = await engine?.hasTmux(on: self) ?? false
        guard available, !isTerminated else { return }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let name = "term-\(id.uuidString.prefix(6).lowercased())"
        send("tmux new-session -A -s \(name) 2>/dev/null || tmux new-session -s \(name)\n")
    }

    /// Probes the remote once per profile (cached on the engine) — exec
    /// channels are cheap, repeating `command -v` per tab is not.
    func detectTmux() async -> Bool {
        guard let path = try? await connection.execute("command -v tmux || true") else {
            return false
        }
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    func send(_ data: ArraySlice<UInt8>) {
        let previous = sendChain
        let shell = self.shell
        sendChain = Task { [weak shell] in
            _ = await previous?.value
            await shell?.send(Array(data))
        }
    }

    func send(_ string: String) {
        send([UInt8](string.utf8)[...])
    }

    func setSize(cols: Int, rows: Int) {
        guard cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        let shell = self.shell
        Task { await shell?.setSize(cols: cols, rows: rows) }
    }

    // MARK: - Reconnect

    /// Reconnecting a tab must not kill the transport other tabs and
    /// SFTP share — the pooled connection decides for itself whether
    /// the transport is dead and re-handshakes lazily.
    func reconnectIfNeeded() async {
        guard state != .connecting, state != .reconnecting else { return }
        guard state == .offline || state.isFailed else { return }
        tmuxChecked = false
        runConnect()
    }

    func reconnect() {
        tmuxChecked = false
        runConnect()
    }

    func terminate() {
        // An in-flight handshake must die with the tab — otherwise it
        // completes later and leaves a zombie transport behind. A live
        // connection is shared, so it's left alone.
        isTerminated = true
        let midConnect = state == .connecting || state == .reconnecting
        connectTask?.cancel()
        connectTask = nil
        sendChain?.cancel()
        sendChain = nil
        consumeTask?.cancel()
        consumeTask = nil
        if let shell {
            self.shell = nil
            Task { await shell.close() }
        }
        state = .offline
        if midConnect {
            Task { await connection.markDisconnected() }
        }
    }

    /// One short human phrase per failure class — never raw error text.
    static func describe(_ error: Error) -> String {
        switch error {
        case is UntrustedHostKey:
            return "Couldn't verify this server"
        case is SSHClient.CommandFailed:
            return "Couldn't open a session"
        default:
            return "Couldn't connect"
        }
    }
}

private extension TerminalSession.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
