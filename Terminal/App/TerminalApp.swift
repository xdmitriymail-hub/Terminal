import SwiftUI

@main
struct TerminalApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
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
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                PrivacyOverlay.shared.update(visible: true, locked: appState.locked, appState: appState)
            case .active:
                if appState.locked {
                    PrivacyOverlay.shared.update(visible: true, locked: true, appState: appState)
                    Task { await appState.unlock() }
                } else {
                    PrivacyOverlay.shared.update(visible: false, locked: false, appState: appState)
                }
            @unknown default:
                break
            }
        }
        .onChange(of: appState.locked) { _, locked in
            guard scenePhase == .active else { return }
            PrivacyOverlay.shared.update(visible: locked, locked: locked, appState: appState)
        }
    }

    private var preferredScheme: ColorScheme? {
        switch appState.settings.settings.appearance {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}
