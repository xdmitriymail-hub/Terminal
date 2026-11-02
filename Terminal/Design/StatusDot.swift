import SwiftUI

/// Session state shown only through color and motion — no text.
struct StatusDot: View {
    enum State: Equatable {
        case connecting, online, reconnecting, offline, failed
    }

    let state: State
    @State private var pulse = false

    private var color: Color {
        switch state {
        case .online: return .terminalAccent
        case .connecting, .reconnecting: return .orange
        case .failed: return .red
        case .offline: return .gray.opacity(0.5)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(pulse ? 0.35 : 1)
            .animation(
                animates
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear { pulse = true }
            .accessibilityHidden(true)
    }

    private var animates: Bool {
        state == .online || state == .connecting || state == .reconnecting
    }
}
