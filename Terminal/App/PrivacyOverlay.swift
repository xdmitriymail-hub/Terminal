import SwiftUI
import UIKit

/// Window-level privacy curtain. A root-view overlay can't cover sheets
/// or alerts, so the curtain lives in its own UIWindow one level above
/// them — content is hidden in the app switcher and while locked.
@MainActor
final class PrivacyOverlay {
    static let shared = PrivacyOverlay()

    private var window: UIWindow?
    private var host: UIHostingController<PrivacyCurtainView>?
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
        if window == nil {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState != .unattached }) else { return }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            let host = UIHostingController(rootView: PrivacyCurtainView(locked: false, onUnlock: {}))
            host.view.backgroundColor = .clear
            window.rootViewController = host
            self.window = window
            self.host = host
        }
        host?.rootView = PrivacyCurtainView(locked: locked) {
            Task { await appState.unlock() }
        }
        window?.isHidden = false
    }

    private func hide() {
        window?.isHidden = true
        window = nil
        host = nil
    }
}

/// Curtain content: lock glyph always, an explicit Unlock button while
/// biometry-locked so a dismissed Face ID prompt is recoverable.
private struct PrivacyCurtainView: View {
    let locked: Bool
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                if locked {
                    Button("Unlock", action: onUnlock)
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
        }
    }
}
