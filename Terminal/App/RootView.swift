import SwiftUI

/// App shell: hosts home ⇄ session workspace, plus the single async
/// host-key trust prompt shared by all connections.
struct RootView: View {
    @EnvironmentObject var engine: SessionEngine
    @EnvironmentObject var keepAlive: KeepAliveEngine
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
    @State private var clipboardRequest: ClipboardRequest?
    @State private var clipboardQueue: [ClipboardRequest] = []
    @State private var showServers = false
    @State private var showSettings = false
    @ObservedObject private var transferManager = TransferManager.shared
    @EnvironmentObject private var appState: AppState

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
                engine.clearPasswordPrompt(for: session)
                passwordSession = nil
                passwordText = ""
            }
        }
        .confirmationDialog(
            hostKeyTitle,
            isPresented: hostKeyPromptPresented,
            titleVisibility: .visible
        ) {
            hostKeyButtons
        } message: {
            hostKeyMessage
        }
        .sheet(isPresented: $showServers) {
            NavigationStack { HostsListView(embeddedInStack: true) }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .confirmationDialog(
            "Allow Clipboard Write",
            isPresented: Binding(
                get: { clipboardRequest != nil },
                set: { if !$0 { resolveClipboard(false) } }
            ),
            titleVisibility: .visible
        ) {
            Button("Allow This Session") { resolveClipboard(true) }
            Button("Deny", role: .cancel) { resolveClipboard(false) }
        } message: {
            if let request = clipboardRequest {
                Text("\(request.session.profile.endpoint) wants to write \(request.data.count) bytes to the clipboard")
            }
        }
        .task {
            engine.hostKeyDecider = { event in
                await askHostKeyTrust(event)
            }
            // The engine cancels a prompt whose connection died — drop
            // the UI side the same way.
            engine.onHostKeyPromptDismissed = {
                Task { @MainActor in dismissHostKeyPrompt() }
            }
            engine.onPasswordPromptDismissed = {
                Task { @MainActor in
                    passwordSession = nil
                    passwordText = ""
                }
            }
            engine.onError = { message in
                errorMessage = message
            }
            engine.onAuthNeeded = { session in
                passwordSession = session
            }
            engine.onClipboardRequest = { session, data in
                clipboardQueue.append(ClipboardRequest(session: session, data: data))
                presentNextClipboard()
            }
            syncKeepAlive()
            FilePreviewView.purgeShareTemps()
            // Cold start under lock: the scenePhase observer never fires
            // for the initial .active, so sync the curtain here.
            if appState.locked {
                PrivacyOverlay.shared.update(visible: true, locked: true, appState: appState)
                await appState.unlock()
            }
        }
        .onChange(of: engine.sessions.isEmpty) { _, _ in
            syncKeepAlive()
        }
        .onChange(of: engine.sessions.map(\.state)) { _, _ in
            syncKeepAlive()
        }
        .onChange(of: transferManager.activeCount) { _, _ in
            syncKeepAlive()
        }
    }

    /// Honest activity signal: live sessions plus transfers actually in
    /// flight — offline tabs alone don't keep the audio engine up.
    private func syncKeepAlive() {
        keepAlive.updateActivity(
            liveSessions: engine.sessions.filter { $0.state == .online }.count,
            activeTransfers: TransferManager.shared.activeCount
        )
    }

    // MARK: - Workspace

    private var workspace: some View {
        NavigationStack {
            ZStack {
                ForEach(engine.sessions) { session in
                    TerminalScreenView(
                        session: session,
                        isActive: session.id == engine.activeSessionID
                    )
                        .opacity(session.id == engine.activeSessionID ? 1 : 0)
                        .allowsHitTesting(session.id == engine.activeSessionID)
                        .zIndex(session.id == engine.activeSessionID ? 1 : 0)
                }
            }
            // Inset, not overlay — terminal content must never slide
            // under the tab bar.
            .safeAreaInset(edge: .bottom, spacing: 0) {
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
                }
                Button {
                    showServers = true
                } label: {
                    Label("Servers", systemImage: "server.rack")
                }
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                if activeSession != nil {
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
            .accessibilityIdentifier("workspaceMenu")
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
        // If the store fails, reconnecting would re-prompt forever —
        // say so instead.
        let status = Keychain.save(text, tag: "password.\(session.profile.id.uuidString)")
        guard status == errSecSuccess else {
            errorMessage = "Couldn't store the password (\(status))"
            return
        }
        session.reconnect()
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

    /// The connect attempt behind the front prompt was cancelled —
    /// answer it with decline so its continuation unwinds cleanly.
    private func dismissHostKeyPrompt() {
        guard pendingHostKey != nil else { return }
        resolveHostKey(false)
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

    private var hostKeyTitle: String {
        if case .changed = pendingHostKey {
            return "Host Key Changed"
        }
        return "Verify Host Key"
    }

    @ViewBuilder
    private var hostKeyButtons: some View {
        if case .changed = pendingHostKey {
            Button("Trust Anyway", role: .destructive) { resolveHostKey(true) }
            Button("Decline", role: .cancel) { resolveHostKey(false) }
        } else {
            Button("Trust") { resolveHostKey(true) }
            Button("Decline", role: .cancel) { resolveHostKey(false) }
        }
    }

    @ViewBuilder
    private var hostKeyMessage: some View {
        switch pendingHostKey {
        case .unknown(let host, let port, let keyLine, let fingerprint):
            Text("First connection to \(host):\(port)\n\(Self.keyAlgorithm(of: keyLine))\n\(fingerprint)")
        case .changed(let host, let port, let keyLine, let expected, let fingerprint):
            Text("The identity of \(host):\(port) changed — verify the new fingerprint out of band.\n\(Self.keyAlgorithm(of: keyLine))\nWas: \(expected)\nNow: \(fingerprint)")
        case .none:
            EmptyView()
        }
    }

    private static func keyAlgorithm(of keyLine: String) -> String {
        keyLine.split(separator: " ").first.map(String.init) ?? "key"
    }

    // MARK: - Clipboard consent

    private struct ClipboardRequest: Identifiable {
        let id = UUID()
        let session: TerminalSession
        let data: Data
    }

    private func presentNextClipboard() {
        guard clipboardRequest == nil else { return }
        clipboardRequest = clipboardQueue.first
    }

    private func resolveClipboard(_ allow: Bool) {
        guard let request = clipboardRequest else { return }
        if !clipboardQueue.isEmpty { clipboardQueue.removeFirst() }
        clipboardRequest = nil
        if allow {
            // Consent is scoped to this tab's lifetime — the label says
            // exactly that, and a fresh session asks again.
            request.session.clipboardAllowed = true
            request.session.clipboardWrite(request.data)
        }
        presentNextClipboard()
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
