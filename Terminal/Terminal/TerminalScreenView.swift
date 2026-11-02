import SwiftUI

/// Full-screen terminal for one session. Pure surface + status dot +
/// a quiet glass strip for connecting/reconnecting/failure — never a
/// wall of text.
struct TerminalScreenView: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var snippets: SnippetsStore
    @EnvironmentObject var engine: SessionEngine
    @Environment(\.colorScheme) private var colorScheme
    private let bar: KeyboardAccessoryView?
    private let externalAccessory: UIView?

    init(session: TerminalSession, accessory: UIView? = nil) {
        self.session = session
        self.externalAccessory = accessory
        if accessory == nil {
            let bar = KeyboardAccessoryView()
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
        ZStack(alignment: .top) {
            TerminalSurface(
                session: session,
                fontSize: settings.settings.fontSize,
                theme: activeTheme,
                accessory: accessory,
                modifiers: bar?.modifiers
            )
            .ignoresSafeArea(.container, edges: .bottom)
            .accessibilityIdentifier("terminalSurface")

            if !snippets.snippets.isEmpty {
                SnippetBar(session: session)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if showsStatus {
                statusStrip
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: session.state)
        .background(activeTheme.background)
        .onChange(of: session.state) { _, new in
            if new == .online { Haptics.connected() }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    StatusDot(state: dotState)
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

    @ViewBuilder
    private var statusStrip: some View {
        switch session.state {
        case .connecting:
            strip {
                ProgressView()
                    .controlSize(.small)
                stripButton("xmark") {
                    Haptics.tap()
                    engine.closeSession(session)
                }
            }
        case .reconnecting:
            strip {
                ProgressView()
                    .controlSize(.small)
            }
        case .failed(let message):
            strip {
                Image(systemName: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                stripButton("arrow.clockwise") {
                    Haptics.tap()
                    Task { await session.reconnect() }
                }
                stripButton("xmark") {
                    Haptics.tap()
                    engine.closeSession(session)
                }
            }
        default:
            EmptyView()
        }
    }

    private func strip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .terminalGlass(cornerRadius: 16)
            .padding(.top, 6)
    }

    private func stripButton(_ glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var dotState: StatusDot.State {
        switch session.state {
        case .connecting: return .connecting
        case .online: return .online
        case .reconnecting: return .reconnecting
        case .offline: return .offline
        case .failed: return .failed
        }
    }
}
