import SwiftUI

/// Floating strip over the terminal: one pill per live session,
/// plus create / overview affordances. State is glyph-only.
struct SessionTabBarView: View {
    @EnvironmentObject private var engine: SessionEngine

    private let onNewSession: () -> Void
    private let onShowGrid: () -> Void

    init(onNewSession: @escaping () -> Void, onShowGrid: @escaping () -> Void = {}) {
        self.onNewSession = onNewSession
        self.onShowGrid = onShowGrid
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

            HStack(spacing: 4) {
                Button {
                    Haptics.tap()
                    onNewSession()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.09), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.tap()
                    onShowGrid()
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.09), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 6)
        }
        .frame(height: 44)
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
                    .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isActive ? 0.16 : 0))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? .primary : .secondary)
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
