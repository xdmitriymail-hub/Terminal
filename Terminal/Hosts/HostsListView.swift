import Combine
import SwiftUI

/// Home screen: a title-free list of servers.
/// Owns its NavigationStack unless pushed inside an existing one
/// (e.g. from onboarding) via `HostsListView(embeddedInStack: true)`.
struct HostsListView: View {
    var embeddedInStack = false

    @EnvironmentObject var profiles: ProfilesStore
    @EnvironmentObject var engine: SessionEngine

    @State private var query = ""
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var editing: ServerProfile?
    @State private var session: TerminalSession?
    @State private var pendingConnect: TerminalSession?
    @State private var errorMessage: String?
    @State private var deleting: ServerProfile?

    var body: some View {
        if embeddedInStack {
            // Pushed inside another stack — the home screen stays
            // title-free, but a pushed destination needs its name.
            content.navigationTitle("Servers")
        } else {
            NavigationStack { content }
        }
    }

    private var filtered: [ServerProfile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return profiles.profiles }
        return profiles.profiles.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || $0.host.localizedCaseInsensitiveContains(q)
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if profiles.profiles.isEmpty {
                EmptyState(
                    symbol: "server.rack",
                    text: String(localized: "No servers"),
                    actionTitle: String(localized: "Add Server"),
                    action: {
                        Haptics.tap()
                        showAdd = true
                    }
                )
            } else {
                List {
                    ForEach(filtered) { profile in
                        row(profile)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .background { pendingObserver }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search")
        .navigationDestination(item: pushedSessionID) { _ in
            if let session {
                TerminalScreenView(session: session)
            }
        }
        .sheet(isPresented: $showAdd) { AddServerView() }
        .sheet(item: $editing) { AddServerView(profile: $0) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert(errorMessage ?? "", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        }
        .alert("Delete \(deleting?.displayName ?? "")?", isPresented: deletePresented, presenting: deleting) { profile in
            Button("Delete", role: .destructive) { delete(profile) }
            Button("Cancel", role: .cancel) {}
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 18) {
                    Button {
                        Haptics.tap()
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("settingsButton")
                    Button {
                        Haptics.tap()
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    /// TerminalSession isn't Hashable, so the push is keyed by its id.
    private var pushedSessionID: Binding<UUID?> {
        Binding(
            get: { session?.id },
            set: { if $0 == nil { session = nil } }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )
    }

    /// The pending session's state stream drives navigation: push on
    /// .online, retire on .failed, wait out a password prompt in
    /// between — and a dismissed prompt retires it too.
    @ViewBuilder
    private var pendingObserver: some View {
        if let pending = pendingConnect {
            PendingWatcher(session: pending, engine: engine) {
                handlePendingState($0)
            } onPromptDismissed: { session in
                guard pendingConnect?.id == session.id,
                      case .failed = session.state else { return }
                pendingConnect = nil
                engine.closeSession(session)
            }
        }
    }

    // MARK: - Rows

    private func row(_ profile: ServerProfile) -> some View {
        Button {
            connect(profile)
        } label: {
            HStack(spacing: 12) {
                serverIcon(profile)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle(profile))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                statusText(profile)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .terminalGlass(cornerRadius: 16)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(HostRowStyle())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                connect(profile)
            } label: {
                Label("Connect", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
            }
            .tint(.terminalAccent)
            .accessibilityLabel("Connect")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleting = profile
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            Button {
                Haptics.tap()
                editing = profile
            } label: {
                Label("Edit", systemImage: "pencil")
                    .labelStyle(.iconOnly)
            }
            .tint(.terminalAccent)
        }
        .contextMenu {
            Button {
                connect(profile)
            } label: {
                Label("Connect", systemImage: "play.fill")
            }
            Button {
                Haptics.tap()
                editing = profile
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                duplicate(profile)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(role: .destructive) {
                deleting = profile
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// "root · Ubuntu 24.04" — identity line, never the raw endpoint.
    private func subtitle(_ profile: ServerProfile) -> String {
        [profile.username, profile.osName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// OS-family glyph: distro monogram where SF Symbols has no logo,
    /// system symbols where it does, plain rack for undetected hosts.
    @ViewBuilder
    private func osGlyph(_ profile: ServerProfile) -> some View {
        switch profile.osID {
        case "darwin", "macos", "ios": Image(systemName: "applelogo")
        case "windows", "mingw64_nt", "cygwin_nt", "msys_nt": Image(systemName: "desktopcomputer")
        case "freebsd", "openbsd", "netbsd": Image(systemName: "internaldrive")
        case "alpine": Image(systemName: "mountain.2.fill")
        case "arch", "archarm", "manjaro": Image(systemName: "triangle.fill")
        case "openwrt", "ddwrt": Image(systemName: "wifi.router")
        case "kali": Image(systemName: "shield.lefthalf.filled")
        case nil: Image(systemName: "server.rack")
        default:
            // Every other distro gets its initial — a distinct badge
            // per OS without fake logos.
            Text(String(profile.osID?.prefix(1) ?? "?").uppercased())
                .font(.system(size: 15, weight: .bold, design: .rounded))
        }
    }

    /// Icon tile; the connect/reconnect states wrap it in a spinning
    /// accent ring so the wait reads as motion, not a dead button.
    private func serverIcon(_ profile: ServerProfile) -> some View {
        ZStack {
            osGlyph(profile)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.terminalAccent)
                .frame(width: 38, height: 38)
                .terminalGlass(cornerRadius: 11)
            if let live = liveSession(for: profile),
               live.state == .connecting || live.state == .reconnecting {
                ConnectRing()
            }
        }
    }

    /// Textual status — green for up, red for down, quiet gray for
    /// everything transitional or untouched.
    @ViewBuilder
    private func statusText(_ profile: ServerProfile) -> some View {
        if let live = liveSession(for: profile) {
            SessionProbe(session: live) { s in
                switch s.state {
                case .online:
                    Text("Online").foregroundStyle(.green)
                case .connecting:
                    Text("Connecting").foregroundStyle(.secondary)
                case .reconnecting:
                    Text("Reconnecting").foregroundStyle(.secondary)
                case .failed:
                    Text("Error").foregroundStyle(.red)
                case .offline:
                    Text("Offline").foregroundStyle(.red.opacity(0.85))
                }
            }
        } else {
            EmptyView()
        }
    }

    // MARK: - Actions

    /// Tapping a row keeps the user in the list: the session connects
    /// in the background (ring on the icon) and only a successful
    /// handshake pushes the terminal. Failures stay here with the
    /// session's own alert.
    private func connect(_ profile: ServerProfile) {
        Haptics.tap()
        pendingConnect = engine.openSession(for: profile, cols: 80, rows: 24)
    }

    private func handlePendingState(_ state: TerminalSession.State) {
        guard let pending = pendingConnect else { return }
        switch state {
        case .online:
            pendingConnect = nil
            session = pending
        case .failed where engine.isAwaitingPassword(pending):
            // A password prompt is up — keep it armed: a resolved
            // prompt reconnects and still reaches .online.
            break
        case .failed:
            pendingConnect = nil
            engine.closeSession(pending)
        default:
            break
        }
    }

    private func delete(_ profile: ServerProfile) {
        Haptics.tap()
        engine.sessions
            .filter { $0.profile.id == profile.id }
            .forEach { engine.closeSession($0) }
        engine.invalidateConnection(for: profile.id)
        FileBrowserViewModel.evictWarm(profileID: profile.id)
        // Also drops the keychain password tag — only after the store write lands.
        if !profiles.delete(profile) {
            Haptics.failed()
            errorMessage = String(localized: "Couldn't delete the server")
        }
    }

    private func duplicate(_ profile: ServerProfile) {
        var copy = profile
        copy.id = UUID()
        copy.lastConnected = nil
        if !copy.name.isEmpty { copy.name = String(localized: "\(copy.name) copy") }
        if let password = Keychain.loadString(tag: "password.\(profile.id.uuidString)"),
           Keychain.save(password, tag: "password.\(copy.id.uuidString)") != errSecSuccess {
            errorMessage = String(localized: "Couldn't copy the password — the new server will ask for it")
        }
        if !profiles.save(copy) {
            Haptics.failed()
            errorMessage = String(localized: "Couldn't save the server")
            return
        }
        Haptics.tap()
    }

    // MARK: - Live sessions

    private func liveSession(for profile: ServerProfile) -> TerminalSession? {
        engine.sessions.first { $0.profile.id == profile.id }
    }

}

/// Watches a pending session and reports state transitions plus the
/// moment its password prompt is dismissed without an answer.
private struct PendingWatcher: View {
    @ObservedObject var session: TerminalSession
    let engine: SessionEngine
    let onState: (TerminalSession.State) -> Void
    let onPromptDismissed: (TerminalSession) -> Void

    var body: some View {
        Color.clear
            .onChange(of: session.state) { _, new in onState(new) }
            .onReceive(engine.$awaitingPasswordIDs) { ids in
                if !ids.contains(session.id) { onPromptDismissed(session) }
            }
    }
}

/// Re-renders whenever the observed session publishes — list rows
/// don't own the session, they borrow its live state.
private struct SessionProbe<Content: View>: View {
    @ObservedObject var session: TerminalSession
    @ViewBuilder var content: (TerminalSession) -> Content

    var body: some View { content(session) }
}

/// Spinning accent arc around a server icon while its handshake runs.
private struct ConnectRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Color.terminalAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 46, height: 46)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}

/// Quiet press feedback — just a fade, no chrome.
struct HostRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

struct HostsListView_Previews: PreviewProvider {
    static var previews: some View {
        HostsListView()
            .environmentObject(ProfilesStore())
            .environmentObject(AppState().engine)
    }
}
