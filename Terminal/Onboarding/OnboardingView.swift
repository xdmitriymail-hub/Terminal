import SwiftUI

/// First-run screen: one glyph, one field, one button.
struct OnboardingView: View {
    @EnvironmentObject var profiles: ProfilesStore
    @EnvironmentObject var engine: SessionEngine

    @State private var quick = ""
    @State private var shake: CGFloat = 0
    @State private var session: TerminalSession?
    @FocusState private var fieldFocused: Bool

    /// Most recently used first.
    private var recent: [ServerProfile] {
        Array(
            profiles.profiles
                .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
                .prefix(4)
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "apple.terminal.fill")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(Color.terminalAccent)

                TextField("user@host", text: $quick)
                    .font(.system(.title3, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($fieldFocused)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 20)
                    .terminalGlass(cornerRadius: 14)
                    .padding(.horizontal, 28)
                    .modifier(ShakeEffect(animatableData: shake))
                    .onSubmit { connect() }

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
                .padding(.horizontal, 28)

                if !recent.isEmpty {
                    recentCard
                        .padding(.top, 12)
                }

                Spacer()
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: pushedSessionID) { _ in
                if let session {
                    TerminalScreenView(session: session)
                }
            }
            .onTapGesture { fieldFocused = false }
        }
    }

    /// TerminalSession isn't Hashable, so the push is keyed by its id.
    private var pushedSessionID: Binding<UUID?> {
        Binding(
            get: { session?.id },
            set: { if $0 == nil { session = nil } }
        )
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
        .padding(.horizontal, 28)
    }

    // MARK: - Connect

    private func connect() {
        guard let parsed = QuickConnectParser.parse(quick, profiles: profiles.profiles) else {
            Haptics.failed()
            withAnimation(.linear(duration: 0.35)) { shake += 1 }
            return
        }
        let profile = parsed.profile
        if let password = parsed.password {
            Keychain.save(password, tag: "password.\(profile.id.uuidString)")
        }
        connect(profile)
    }

    private func connect(_ profile: ServerProfile) {
        Haptics.tap()
        UserDefaults.standard.set(true, forKey: "onboarding.done")
        profiles.save(profile)
        session = engine.openSession(for: profile, cols: 80, rows: 24)
    }
}

/// Brief horizontal wobble for a rejected quick-connect line.
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = -8 * sin(animatableData * .pi * 4)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView()
            .environmentObject(ProfilesStore())
            .environmentObject(AppState().engine)
    }
}
