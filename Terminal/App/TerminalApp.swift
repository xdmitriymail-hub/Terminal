import SwiftUI

@main
struct TerminalApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPrivacyCurtain = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(appState)
                    .environmentObject(appState.profiles)
                    .environmentObject(appState.keys)
                    .environmentObject(appState.knownHosts)
                    .environmentObject(appState.snippets)
                    .environmentObject(appState.settings)
                    .environmentObject(appState.engine)
                    .environmentObject(appState.keepAlive)
                    .preferredColorScheme(preferredScheme)

                if appState.locked || showPrivacyCurtain {
                    privacyCurtain
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: appState.locked || showPrivacyCurtain)
            .task {
                if appState.locked {
                    await appState.unlock()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                showPrivacyCurtain = true
            case .active:
                // Small delay so the curtain doesn't flicker on quick app switches.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    showPrivacyCurtain = false
                }
            @unknown default:
                break
            }
        }
    }

    private var preferredScheme: ColorScheme? {
        switch appState.settings.settings.appearance {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    /// Curtain over scrollback content in the app switcher / while locked —
    /// the glyph is the only thing visible.
    private var privacyCurtain: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(systemName: "lock.fill")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
        }
    }
}
