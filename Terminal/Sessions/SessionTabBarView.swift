import SwiftUI

/// Floating strip over the terminal: one pill per live session,
/// plus create / overview affordances. State is glyph-only.
struct SessionTabBarView: View {
    @EnvironmentObject private var engine: SessionEngine

    private let onNewSession: () -> Void

    init(onNewSession: @escaping () -> Void) {
        self.onNewSession = onNewSession
    }

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(engine.sessions) { session in
                            SessionPillView(session: session)
                                .id(session.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: engine.activeSessionID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            HStack(spacing: 0) {
                Button {
                    Haptics.tap()
                    onNewSession()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New session")
            }
            .padding(.trailing, 4)
        }
        .frame(minHeight: 44)
        .terminalGlass(cornerRadius: 22)
        .padding(.horizontal, 12)
    }
}

/// One session pill: status dot + title. Tap activates, long-press
/// offers reconnect / close.
private struct SessionPillView: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var engine: SessionEngine

    private var isActive: Bool {
        engine.activeSessionID == session.id
    }

    var body: some View {
        Button {
            Haptics.select()
            engine.activeSessionID = session.id
        } label: {
            HStack(spacing: 7) {
                StatusDot(state: StatusDot.State(session.state))
                Text(session.title)
                    .font(.system(.subheadline, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isActive ? 0.16 : 0))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? .primary : .secondary)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .contextMenu {
            Button {
                session.reconnect()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                engine.closeSession(session)
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
    }
}
