import SwiftUI
import UIKit

/// Window-level privacy curtain. A root-view overlay can't cover sheets
/// or alerts, so the curtain lives in its own UIWindow one level above
/// them — one per scene, so multi-window iPad sessions are covered too.
@MainActor
final class PrivacyOverlay {
    static let shared = PrivacyOverlay()

    private var windows: [ObjectIdentifier: UIWindow] = [:]
    private var hosts: [ObjectIdentifier: UIHostingController<PrivacyCurtainView>] = [:]
    private var hideTask: Task<Void, Never>?

    func update(visible: Bool, locked: Bool, appState: AppState) {
        hideTask?.cancel()
        hideTask = nil
        if visible {
            show(locked: locked, appState: appState)
        } else {
            // Debounce — control-center swipes toggle inactive/active
            // rapidly and must not flash the curtain.
            hideTask = Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                hide()
            }
        }
    }

    private func show(locked: Bool, appState: AppState) {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState != .unattached }

        // Drop windows whose scene went away.
        let live = Set(scenes.map { ObjectIdentifier($0) })
        for id in windows.keys where !live.contains(id) {
            windows[id]?.isHidden = true
            windows[id] = nil
            hosts[id] = nil
        }

        for scene in scenes {
            let id = ObjectIdentifier(scene)
            if windows[id] == nil {
                let window = UIWindow(windowScene: scene)
                window.windowLevel = .alert + 1
                let host = UIHostingController(rootView: PrivacyCurtainView(locked: false, onUnlock: {}))
                host.view.backgroundColor = .clear
                window.rootViewController = host
                windows[id] = window
                hosts[id] = host
            }
            hosts[id]?.rootView = PrivacyCurtainView(locked: locked) {
                Task { await appState.unlock() }
            }
            windows[id]?.isHidden = false
        }
    }

    private func hide() {
        for (_, window) in windows { window.isHidden = true }
        windows.removeAll()
        hosts.removeAll()
    }
}

/// Curtain content. A plain lock on system material — the app switcher
/// should look like iOS, not a glowing emblem. Unlock is only there
/// when Face ID was cancelled and the user has to ask again.
private struct PrivacyCurtainView: View {
    let locked: Bool
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.secondary)
                if locked {
                    Button("Unlock", action: onUnlock)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
        }
    }
}
