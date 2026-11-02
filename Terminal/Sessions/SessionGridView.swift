import SwiftUI

/// Overview sheet: every live session as a dark glass card.
/// Tap to focus, xmark to close.
struct SessionGridView: View {
    @EnvironmentObject private var engine: SessionEngine
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.terminalSurface.ignoresSafeArea()

                if engine.sessions.isEmpty {
                    EmptyState(symbol: "rectangle.stack")
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
                            .background(.white.opacity(0.1), in: Circle())
                    }
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

    var body: some View {
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
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
            }

            Text(session.profile.endpoint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .terminalGlass(cornerRadius: 16)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onSelect)
    }
}
