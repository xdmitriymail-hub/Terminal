import SwiftUI

/// App shell: hosts home ⇄ session workspace, plus the single async
/// host-key trust prompt shared by all connections.
struct RootView: View {
    @EnvironmentObject var engine: SessionEngine
    @AppStorage("onboarding.done") private var onboardingDone = false

    @State private var showSessionPicker = false
    @State private var showGrid = false
    @State private var showFilesFor: ServerProfile?
    @State private var showForwardsFor: ServerProfile?
    @State private var errorMessage: String?
    @State private var passwordSession: TerminalSession?
    @State private var passwordText = ""

    // Host key prompt plumbing — a queue: parallel connects (e.g.
    // bastion + target) must not clobber a pending prompt's continuation.
    @State private var pendingHostKey: HostKeyEvent?
    @State private var hostKeyQueue: [(HostKeyEvent, CheckedContinuation<Bool, Never>)] = []
    @State private var hostKeyPromptActive = false

    var body: some View {
        ZStack {
            if engine.sessions.isEmpty {
                HostsListView()
            } else {
                workspace
            }
            // Inline, not a cover — host-key and password prompts must
            // be able to appear above it during the first connect.
            if !onboardingDone && engine.sessions.isEmpty {
                OnboardingView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .sheet(isPresented: $showSessionPicker) {
            SessionPickerSheet()
        }
        .sheet(isPresented: $showGrid) {
            SessionGridView()
        }
        .sheet(item: $showFilesFor) { profile in
            NavigationStack {
                FileBrowserView(profile: profile)
            }
        }
        .sheet(item: $showForwardsFor) { profile in
            NavigationStack {
                PortForwardsView(profile: profile)
            }
        }
        .alert(errorMessage ?? "", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        }
        .alert(
            "Password",
            isPresented: passwordPromptPresented,
            presenting: passwordSession
        ) { session in
            SecureField(session.profile.endpoint, text: $passwordText)
            Button("Connect") { submitPassword() }
            Button("Cancel", role: .cancel) {
                passwordSession = nil
                passwordText = ""
            }
        }
        .confirmationDialog(
            pendingHostKey.map { _ in "" } ?? "",
            isPresented: hostKeyPromptPresented,
            titleVisibility: .visible
        ) {
            hostKeyButtons
        } message: {
            hostKeyMessage
        }
        .task {
            engine.hostKeyDecider = { event in
                await askHostKeyTrust(event)
            }
            engine.onError = { message in
                errorMessage = message
            }
            engine.onAuthNeeded = { session in
                passwordSession = session
            }
        }
    }

    // MARK: - Workspace

    private var workspace: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ForEach(engine.sessions) { session in
                    TerminalScreenView(session: session)
                        .opacity(session.id == engine.activeSessionID ? 1 : 0)
                        .allowsHitTesting(session.id == engine.activeSessionID)
                        .zIndex(session.id == engine.activeSessionID ? 1 : 0)
                }

                SessionTabBarView(
                    onNewSession: { showSessionPicker = true },
                    onShowGrid: { showGrid = true }
                )
                .padding(.bottom, 4)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { workspaceToolbar }
        }
    }

    // MARK: - Toolbars

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSessionPicker = true
                Haptics.tap()
            } label: {
                Image(systemName: "square.grid.2x2")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let profile = activeProfile {
                    Button {
                        showFilesFor = profile
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                    Button {
                        showForwardsFor = profile
                    } label: {
                        Label("Forwards", systemImage: "arrow.left.arrow.right")
                    }
                    Button {
                        Task { await activeSession?.reconnect() }
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    Divider()
                    Button(role: .destructive) {
                        if let s = activeSession { engine.closeSession(s) }
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var activeSession: TerminalSession? {
        engine.sessions.first { $0.id == engine.activeSessionID }
    }

    private var activeProfile: ServerProfile? {
        activeSession?.profile
    }

    // MARK: - Bindings

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var hostKeyPromptPresented: Binding<Bool> {
        Binding(
            get: { pendingHostKey != nil },
            set: { if !$0 { resolveHostKey(false) } }
        )
    }

    private var passwordPromptPresented: Binding<Bool> {
        Binding(
            get: { passwordSession != nil },
            set: { if !$0 { passwordSession = nil; passwordText = "" } }
        )
    }

    /// Stores the entered password for the profile and retries the
    /// same session — no second trip through the server list.
    private func submitPassword() {
        guard let session = passwordSession else { return }
        let text = passwordText
        passwordSession = nil
        passwordText = ""
        guard !text.isEmpty else { return }
        Keychain.save(text, tag: "password.\(session.profile.id.uuidString)")
        Task { await session.reconnect() }
    }

    // MARK: - Host key prompt

    private func askHostKeyTrust(_ event: HostKeyEvent) async -> Bool {
        await withCheckedContinuation { cont in
            hostKeyQueue.append((event, cont))
            presentNextHostKey()
        }
    }

    private func presentNextHostKey() {
        guard !hostKeyPromptActive, let (event, _) = hostKeyQueue.first else { return }
        hostKeyPromptActive = true
        pendingHostKey = event
    }

    private func resolveHostKey(_ allow: Bool) {
        guard let (_, cont) = hostKeyQueue.first else {
            pendingHostKey = nil
            hostKeyPromptActive = false
            return
        }
        hostKeyQueue.removeFirst()
        cont.resume(returning: allow)
        pendingHostKey = nil
        hostKeyPromptActive = false
        if allow { Haptics.connected() } else { Haptics.failed() }
        presentNextHostKey()
    }

    @ViewBuilder
    private var hostKeyButtons: some View {
        if case .changed = pendingHostKey {
            Button("Trust", role: .destructive) { resolveHostKey(true) }
            Button("Cancel", role: .cancel) { resolveHostKey(false) }
        } else {
            Button("Trust") { resolveHostKey(true) }
            Button("Cancel", role: .cancel) { resolveHostKey(false) }
        }
    }

    @ViewBuilder
    private var hostKeyMessage: some View {
        switch pendingHostKey {
        case .unknown(let host, _, _, _):
            Text("First connection to \(host)")
        case .changed(let host, _, _, _, let fingerprint):
            Text("The identity of \(host) changed\n\(fingerprint)")
        case .none:
            EmptyView()
        }
    }
}

/// Pick a saved server to open a new tab.
struct SessionPickerSheet: View {
    @EnvironmentObject var profiles: ProfilesStore
    @EnvironmentObject var engine: SessionEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(profiles.profiles) { profile in
                Button {
                    engine.openSession(for: profile, cols: 80, rows: 24)
                    dismiss()
                    Haptics.tap()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(Color.terminalAccent)
                        Text(profile.displayName)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.terminalSurface.ignoresSafeArea())
            .overlay {
                if profiles.profiles.isEmpty {
                    EmptyState(symbol: "server.rack", text: nil)
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(7)
                            .background(Color.primary.opacity(0.1), in: Circle())
                    }
                }
            }
        }
    }
}
