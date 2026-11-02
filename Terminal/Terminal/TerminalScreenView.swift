import SwiftUI

/// Full-screen terminal for one session. Pure surface + status dot +
/// a quiet glass capsule for connecting/reconnecting/failure — never
/// a wall of text.
struct TerminalScreenView: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var snippets: SnippetsStore
    @EnvironmentObject var engine: SessionEngine
    @Environment(\.colorScheme) private var colorScheme
    var isActive = true
    private let bar: KeyboardAccessoryView?
    private let externalAccessory: UIView?

    init(session: TerminalSession, accessory: UIView? = nil, isActive: Bool = true) {
        self.session = session
        self.externalAccessory = accessory
        self.isActive = isActive
        if accessory == nil {
            let bar = KeyboardAccessoryView()
            bar.bind(modifiers: session.modifiers)
            bar.onSend = { [weak session] bytes in
                session?.send(ArraySlice(bytes))
            }
            self.bar = bar
        } else {
            self.bar = nil
        }
    }

    private var accessory: UIView? {
        settings.settings.showKeyboardBar ? (bar ?? externalAccessory) : nil
    }

    /// "auto" follows the interface style; explicit ids stay pinned.
    private var activeTheme: TerminalTheme {
        let id = settings.settings.themeID
        if id == "auto" { return colorScheme == .dark ? .pro : .paper }
        return TerminalTheme.theme(id: id)
    }

    var body: some View {
        TerminalSurface(
            session: session,
            fontSize: settings.settings.fontSize,
            theme: activeTheme,
            accessory: accessory,
            modifiers: session.modifiers,
            isActive: isActive
        )
        .accessibilityIdentifier("terminalSurface")
        .accessibilityHidden(!isActive)
        // Chrome insets reserve space — the surface itself never draws
        // under the tab bar, and the theme color still reaches the
        // screen edges so no dark corners show around the keyboard.
        .background(activeTheme.background.ignoresSafeArea(.container))
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                if !snippets.snippets.isEmpty {
                    SnippetBar(session: session)
                }
                if showsStatus {
                    statusBadge
                }
            }
            .animation(.spring(duration: 0.3), value: session.state)
        }
        .onChange(of: session.state) { _, new in
            if new == .online { Haptics.connected() }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    StatusDot(state: StatusDot.State(session.state))
                    Text(session.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
            }
        }
    }

    private var showsStatus: Bool {
        switch session.state {
        case .connecting, .reconnecting, .failed: return true
        default: return false
        }
    }

    // MARK: - Status badge

    /// Floating capsule: spinner + one word + quiet actions.
    @ViewBuilder
    private var statusBadge: some View {
        switch session.state {
        case .connecting:
            badge {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting")
                badgeButton("xmark", label: "Cancel") {
                    Haptics.tap()
                    engine.closeSession(session)
                }
            }
        case .reconnecting:
            badge {
                ProgressView()
                    .controlSize(.small)
                Text("Reconnecting")
            }
        case .failed(let message):
            badge {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(message)
                    .lineLimit(1)
                    .frame(maxWidth: 220)
                badgeButton("arrow.clockwise", label: "Retry") {
                    Haptics.tap()
                    session.reconnect()
                }
                badgeButton("xmark", label: "Close") {
                    Haptics.tap()
                    engine.closeSession(session)
                }
            }
        default:
            EmptyView()
        }
    }

    private func badge<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .terminalGlass(cornerRadius: 19)
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .padding(.top, 2)
    }

    private func badgeButton(_ glyph: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.1), in: Circle())
                // 28pt visual, ≥44pt hit — the capsule stays slim.
                .contentShape(Circle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

}
