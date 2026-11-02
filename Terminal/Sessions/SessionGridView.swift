import SwiftUI

/// Overview sheet: every live session as a dark glass card.
/// Tap to focus, xmark to close.
struct SessionGridView: View {
    @EnvironmentObject private var engine: SessionEngine
    @Environment(\.dismiss) private var dismiss

    /// Grows to 3+ columns on wide screens, shrinks margins at any
    /// Dynamic Type size.
    private let columns = [
        GridItem(.adaptive(minimum: 170), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.terminalSurface.ignoresSafeArea()

                if engine.sessions.isEmpty {
                    EmptyState(symbol: "rectangle.stack", text: String(localized: "No open sessions"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(engine.sessions) { session in
                                SessionCardView(session: session) {
                                    engine.activeSessionID = session.id
                                    Haptics.select()
                                    dismiss()
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(7)
                            .background(Color.primary.opacity(0.1), in: Circle())
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }
}

/// One session card: dot + title, endpoint underneath, close top-trailing.
private struct SessionCardView: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var engine: SessionEngine
    let onSelect: () -> Void

    private var isActive: Bool {
        engine.activeSessionID == session.id
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(state: StatusDot.State(session.state))
                    Text(session.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Button {
                        Haptics.tap()
                        engine.closeSession(session)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(5)
                            .background(Color.primary.opacity(0.12), in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            // 44pt hit area without growing the row.
                            .padding(-12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }

                Text(session.profile.endpoint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .terminalGlass(cornerRadius: 16)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
