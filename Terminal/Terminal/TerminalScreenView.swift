import SwiftUI

/// Full-screen terminal for one session. Pure surface + status dot +
/// a quiet glass strip when reconnecting — never a wall of text.
struct TerminalScreenView: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var snippets: SnippetsStore
    var accessory: UIView?

    init(session: TerminalSession, accessory: UIView? = nil) {
        self.session = session
        if let accessory {
            self.accessory = accessory
        } else {
            // Terminal always needs Esc/Ctrl/arrows — build the bar here
            // so pushed screens get the same keys as the workspace.
            let bar = KeyboardAccessoryView()
            bar.onSend = { [weak session] bytes in
                session?.send(ArraySlice(bytes))
            }
            self.accessory = bar
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            TerminalSurface(
                session: session,
                fontSize: settings.settings.fontSize,
                theme: TerminalTheme.theme(id: settings.settings.themeID),
                accessory: accessory
            )
            .ignoresSafeArea(.container, edges: .bottom)

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
        .background(TerminalTheme.theme(id: settings.settings.themeID).background)
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
        session.state == .reconnecting
    }

    private var statusStrip: some View {
        ProgressView()
            .controlSize(.small)
            .padding(10)
            .terminalGlass(cornerRadius: 16)
            .padding(.top, 6)
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
