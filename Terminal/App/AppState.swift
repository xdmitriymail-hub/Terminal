import Foundation
import SwiftUI

/// Root application state: stores, session engine, keep-alive, app lock.
@MainActor
final class AppState: ObservableObject {
    let profiles = ProfilesStore()
    let keys = KeysStore()
    let knownHosts = KnownHostsStore()
    let snippets = SnippetsStore()
    let settings = SettingsStore()
    let keepAlive = KeepAliveEngine()

    private(set) lazy var engine = SessionEngine(
        profiles: profiles,
        keys: keys,
        knownHosts: knownHosts,
        settings: settings
    )

    @Published var locked = false

    init() {
        if settings.settings.requireBiometry {
            locked = true
        }
        Haptics.setEnabled(settings.settings.haptics)
        keepAlive.setEnabled(settings.settings.keepAlive)
    }

    func unlock() async {
        guard locked else { return }
        if await BiometricGate.evaluate("Unlock Terminal") {
            locked = false
        }
    }
}
