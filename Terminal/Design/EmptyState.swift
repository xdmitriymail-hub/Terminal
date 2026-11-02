import SwiftUI

/// Apple-style empty state: one glyph, at most one line, one action.
struct EmptyState: View {
    let symbol: String
    var text: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            if let text, !text.isEmpty {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.terminalAccent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
