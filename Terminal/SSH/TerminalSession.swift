import Foundation
import SwiftUI
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
    private var cols = 80
    private var rows = 24
    private var hadLiveSession = false
    private var tmuxChecked = false

    /// Terminal view attaches here: raw output bytes to render.
    /// Title/bell go through the SwiftTerm delegate directly.
    var onOutput: (@MainActor (ArraySlice<UInt8>) -> Void)?

    var wantsReconnect: Bool { hadLiveSession && state != .offline }

    init(profile: ServerProfile, connection: SSHConnection, settings: SettingsStore) {
        self.profile = profile
        self.connection = connection
        self.settings = settings
        self.title = profile.displayName
    }

    func start(cols: Int, rows: Int) async {
        self.cols = cols
        self.rows = rows
        await connect()
    }

    private func connect() async {
        state = hadLiveSession ? .reconnecting : .connecting
        do {
            let shell = try await connection.openShell(cols: cols, rows: rows)
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
            state = .failed(Self.describe(error))
            engine?.reportError(Self.describe(error))
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
                            self.onOutput?(ArraySlice(data))
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

    /// Detects tmux on the server once, then reattaches a persistent session.
    private func reattachIfNeeded() async {
        guard profile.autoTmux, settings.settings.autoTmux, !tmuxChecked else { return }
        tmuxChecked = true
        guard let path = try? await connection.execute("command -v tmux || true"),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        send("tmux new-session -A -s main 2>/dev/null || tmux new-session -s main\n")
    }

    // MARK: - Input

    func send(_ data: ArraySlice<UInt8>) {
        shell?.send(Array(data))
    }

    func send(_ string: String) {
        shell?.send(string)
    }

    func setSize(cols: Int, rows: Int) {
        guard cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        shell?.setSize(cols: cols, rows: rows)
    }

    func keepAlive() {
        shell?.keepAlive()
    }

    // MARK: - Reconnect

    func reconnectIfNeeded() async {
        guard state != .connecting, state != .reconnecting else { return }
        guard state == .offline || state.isFailed else { return }
        await connection.markDisconnected()
        await connect()
    }

    func reconnect() async {
        await connection.markDisconnected()
        await connect()
    }

    func terminate() {
        consumeTask?.cancel()
        consumeTask = nil
        shell?.close()
        shell = nil
        state = .offline
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
