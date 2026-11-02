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
    @State private var errorMessage: String?

    var body: some View {
        if embeddedInStack {
            content
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
                EmptyState(symbol: "server.rack", text: nil)
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

    // MARK: - Rows

    private func row(_ profile: ServerProfile) -> some View {
        Button {
            connect(profile)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.terminalAccent)
                    .frame(width: 38, height: 38)
                    .terminalGlass(cornerRadius: 11)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(profile.endpoint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let live = liveSession(for: profile) {
                    StatusDot(state: dotState(live.state))
                }
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
                Image(systemName: "play.fill")
            }
            .tint(.terminalAccent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                delete(profile)
            } label: {
                Image(systemName: "trash")
            }
            Button {
                Haptics.tap()
                editing = profile
            } label: {
                Image(systemName: "pencil")
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
                delete(profile)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func connect(_ profile: ServerProfile) {
        Haptics.tap()
        session = engine.openSession(for: profile, cols: 80, rows: 24)
    }

    private func delete(_ profile: ServerProfile) {
        Haptics.tap()
        engine.sessions
            .filter { $0.profile.id == profile.id }
            .forEach { engine.closeSession($0) }
        engine.invalidateConnection(for: profile.id)
        FileBrowserViewModel.evictWarm(profileID: profile.id)
        profiles.delete(profile) // also drops the keychain password tag
    }

    private func duplicate(_ profile: ServerProfile) {
        var copy = profile
        copy.id = UUID()
        copy.lastConnected = nil
        if !copy.name.isEmpty { copy.name += " copy" }
        if let password = Keychain.loadString(tag: "password.\(profile.id.uuidString)"),
           Keychain.save(password, tag: "password.\(copy.id.uuidString)") != errSecSuccess {
            errorMessage = "Couldn't copy the password — the new server will ask for it"
        }
        profiles.save(copy)
        Haptics.tap()
    }

    // MARK: - Live sessions

    private func liveSession(for profile: ServerProfile) -> TerminalSession? {
        engine.sessions.first { $0.profile.id == profile.id }
    }

    private func dotState(_ state: TerminalSession.State) -> StatusDot.State {
        switch state {
        case .connecting: return .connecting
        case .online: return .online
        case .reconnecting: return .reconnecting
        case .offline: return .offline
        case .failed: return .failed
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
