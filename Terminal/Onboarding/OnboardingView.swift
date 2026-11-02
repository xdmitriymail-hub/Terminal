import SwiftUI

/// First-run screen: what the app is, then a plain labeled form —
/// no ssh syntax knowledge required. Inline in RootView so host-key
/// and password prompts can layer above it.
struct OnboardingView: View {
    @EnvironmentObject var profiles: ProfilesStore
    @EnvironmentObject var engine: SessionEngine
    @AppStorage("onboarding.done") private var done = false

    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case host, port, username, password }

    /// Most recently used first.
    private var recent: [ServerProfile] {
        Array(
            profiles.profiles
                .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
                .prefix(4)
        )
    }

    private var valid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    hero
                        .padding(.top, 26)

                    formCard

                    Button {
                        connect()
                    } label: {
                        Text("Connect")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.terminalAccent)
                    .disabled(!valid)
                    .padding(.horizontal, 24)

                    if !recent.isEmpty {
                        recentCard
                    }

                    Button("Set up later") {
                        done = true
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 30)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .onTapGesture { focus = nil }
        }
    }

    // MARK: - Hero

    /// The icon's motif, alive: a black squircle with a `>` prompt and
    /// a blinking block cursor — the whole app in one glance.
    private var hero: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(red: 0.06, green: 0.06, blue: 0.07))
                .frame(width: 96, height: 96)
                .overlay {
                    HStack(spacing: 5) {
                        Text(">")
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                        BlinkingCursor()
                    }
                    .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)

            Text("Terminal")
                .font(.title.weight(.bold))

            HStack(spacing: 22) {
                featureGlyph("apple.terminal")
                featureGlyph("folder")
                featureGlyph("arrow.left.arrow.right")
            }
        }
    }

    private func featureGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Color.terminalAccent)
            .frame(width: 44, height: 44)
            .terminalGlass(cornerRadius: 13)
    }

    // MARK: - Form

    private var formCard: some View {
        VStack(spacing: 0) {
            field("Host", text: $host, focused: .host,
                  placeholder: "server.example.com",
                  submit: { focus = .username })
            Divider().padding(.leading, 16)
            HStack(spacing: 12) {
                field("Username", text: $username, focused: .username,
                      placeholder: "root",
                      submit: { focus = .password })
                field("Port", text: $port, focused: .port,
                      placeholder: "22", numeric: true,
                      submit: { focus = .password })
                    .frame(maxWidth: 92)
            }
            Divider().padding(.leading, 16)
            field("Password", text: $password, focused: .password,
                  placeholder: "Optional", secure: true,
                  submit: connect)
        }
        .terminalGlass(cornerRadius: 16)
        .padding(.horizontal, 24)
    }

    private func field(_ title: String, text: Binding<String>, focused: Field,
                       placeholder: String, secure: Bool = false,
                       numeric: Bool = false, submit: @escaping () -> Void) -> some View {
        LabeledContent {
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .multilineTextAlignment(.trailing)
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(numeric ? .numberPad : .URL)
            .submitLabel(.next)
            .focused($focus, equals: focused)
            .onSubmit(submit)
        } label: {
            Text(title)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - Existing servers

    private var recentCard: some View {
        VStack(spacing: 0) {
            ForEach(recent) { profile in
                Button {
                    connect(profile)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.subheadline)
                            .foregroundStyle(Color.terminalAccent)
                        Text(profile.displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HostRowStyle())

                if profile.id != recent.last?.id {
                    Divider().padding(.leading, 44)
                }
            }

            Divider().padding(.leading, 16)

            NavigationLink {
                HostsListView(embeddedInStack: true)
            } label: {
                HStack {
                    Text("Servers")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .terminalGlass(cornerRadius: 16)
        .padding(.horizontal, 24)
    }

    // MARK: - Connect

    private func connect() {
        var profile = ServerProfile()
        var rawHost = host.trimmingCharacters(in: .whitespaces)
        var rawUser = username.trimmingCharacters(in: .whitespaces)

        // A pasted "user@host[:port]" or ssh:// line in the host field
        // still works — split it apart instead of rejecting the paste.
        if rawHost.contains("@") || rawHost.contains(":") || rawHost.contains(" "),
           let parsed = QuickConnectParser.parse(rawHost, profiles: profiles.profiles) {
            rawHost = parsed.profile.host
            if rawUser.isEmpty { rawUser = parsed.profile.username }
            if port == "22" { profile.port = parsed.profile.port }
            if password.isEmpty, let pw = parsed.password { password = pw }
        }

        profile.host = rawHost
        profile.username = rawUser
        if let p = Int(port), (1...65535).contains(p) { profile.port = p }
        profile.auth = .password

        guard !profile.host.isEmpty, !profile.username.isEmpty else {
            Haptics.failed()
            return
        }
        if !password.isEmpty {
            Keychain.save(password, tag: "password.\(profile.id.uuidString)")
        }
        connect(profile)
    }

    private func connect(_ profile: ServerProfile) {
        Haptics.tap()
        done = true
        profiles.save(profile)
        engine.openSession(for: profile, cols: 80, rows: 24)
    }
}

/// A block cursor that blinks, like the real thing.
private struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white)
            .frame(width: 17, height: 30)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.53).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView()
            .environmentObject(ProfilesStore())
            .environmentObject(AppState().engine)
    }
}
