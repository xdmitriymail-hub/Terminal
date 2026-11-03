import Combine
import SwiftUI

/// Home screen: a title-free list of servers.
/// Owns its NavigationStack unless pushed inside an existing one
/// (e.g. from onboarding) via `HostsListView(embeddedInStack: true)`.
struct HostsListView: View {
    var embeddedInStack = false

    @EnvironmentObject var profiles: ProfilesStore
    @EnvironmentObject var engine: SessionEngine
    @ObservedObject private var presence = ServerPresence.shared
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var editing: ServerProfile?
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
        .task(id: presenceKey) {
            presence.refresh(profiles.profiles)
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
                    identityLine(profile)
                }

                Spacer(minLength: 8)
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

    /// "root, ubuntu, online" — the last word is whether the machine
    /// answers, colored, and it is not the state of a terminal tab.
    private func identityLine(_ profile: ServerProfile) -> some View {
        let head = [profile.username, profile.osID]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let up = serverUp(profile)
        return HStack(spacing: 0) {
            if !head.isEmpty {
                Text(head)
                    .foregroundStyle(.secondary)
            }
            if let up {
                if !head.isEmpty {
                    Text(", ")
                        .foregroundStyle(.secondary)
                }
                Group {
                    if up {
                        Text("Online")
                    } else {
                        Text("Offline")
                    }
                }
                .foregroundStyle(up ? Color.green : Color.red)
            }
        }
        .font(.subheadline)
        .lineLimit(1)
    }

    /// A live shell proves the host is up. Otherwise the TCP probe.
    private func serverUp(_ profile: ServerProfile) -> Bool? {
        if let live = liveSession(for: profile), live.state == .online {
            return true
        }
        return presence.online[profile.id]
    }

    private var presenceKey: String {
        profiles.profiles.map { "\($0.id.uuidString):\($0.host):\($0.port)" }.joined(separator: "|")
    }

    private func osGlyph(_ profile: ServerProfile) -> some View {
        OSMark(osID: profile.osID)
    }

    /// Icon tile; the connect/reconnect states wrap it in a spinning
    /// accent ring so the wait reads as motion, not a dead button.
    private func serverIcon(_ profile: ServerProfile) -> some View {
        ZStack {
            osGlyph(profile)
                .frame(width: 36, height: 36)
            if let live = liveSession(for: profile),
               live.state == .connecting || live.state == .reconnecting {
                ConnectRing()
            }
        }
    }

    // MARK: - Actions

    /// Tapping a row keeps the user in the list: the session connects
    /// in the background (ring on the icon) and only a successful
    /// handshake pushes the terminal. Failures stay here with the
    /// session's own alert. A profile that already has a live tab in
    /// the workspace is surfaced there instead — never a second
    /// terminal stacked on top of the first.
    private func connect(_ profile: ServerProfile) {
        Haptics.tap()
        if let live = liveSession(for: profile) {
            engine.activeSessionID = live.id
            dismiss()
            return
        }
        // A superseded pending connect would linger unobserved —
        // retire it before arming the new one.
        if let stale = pendingConnect {
            pendingConnect = nil
            engine.closeSession(stale)
        }
        pendingConnect = engine.openSession(for: profile, cols: 80, rows: 24)
    }

    private func handlePendingState(_ state: TerminalSession.State) {
        guard let pending = pendingConnect else { return }
        switch state {
        case .online:
            pendingConnect = nil
            // Standalone: RootView swaps the list for the workspace as
            // soon as a session reaches online — nothing to push.
            // In the servers sheet: the new tab lives in the workspace
            // underneath — surface it and drop the sheet instead of
            // stacking a second terminal inside the list.
            if embeddedInStack {
                engine.activeSessionID = pending.id
                dismiss()
            }
        case .failed where engine.isAwaitingPassword(pending):
            // A password prompt is up — keep it armed: a resolved
            // prompt reconnects and still reaches .online.
            break
        case .failed:
            pendingConnect = nil
            engine.closeSession(pending)
        case .offline:
            // A server that drops the shell mid-setup would otherwise
            // leave the icon ring spinning forever.
            pendingConnect = nil
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

/// Watches a pending session and reports state transitions plus the
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
                spinning = false
                DispatchQueue.main.async {
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                        spinning = true
                    }
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
