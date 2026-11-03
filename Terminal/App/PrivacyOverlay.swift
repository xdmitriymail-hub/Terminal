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

/// Curtain content: a large glass lock emblem always — an explicit
/// Unlock button only while biometry-locked so a dismissed Face ID
/// prompt stays recoverable.
private struct PrivacyCurtainView: View {
    let locked: Bool
    let onUnlock: () -> Void

    @State private var ringGlow = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 40) {
                ZStack {
                    // Soft accent halo breathing behind the emblem —
                    // motion instead of decoration.
                    Circle()
                        .fill(Color.terminalAccent.opacity(0.14))
                        .frame(width: 156, height: 156)
                        .blur(radius: 26)
                        .scaleEffect(ringGlow ? 1.12 : 0.96)
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 112, height: 112)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.35),
                                            Color.white.opacity(0.08)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 1
                                )
                        )
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(.primary.opacity(0.92))
                        .symbolRenderingMode(.hierarchical)
                }
                if locked {
                    Button(action: onUnlock) {
                        Label("Unlock", systemImage: "faceid")
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 30)
                            .padding(.vertical, 14)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityHint(String(localized: "Uses Face ID or passcode"))
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                ringGlow = true
            }
        }
    }
}
