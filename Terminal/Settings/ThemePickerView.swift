import SwiftUI

/// Theme gallery: each option is a miniature terminal mock —
/// real colors, no descriptions. Accent ring marks the pick.
struct ThemePickerView: View {
    @EnvironmentObject private var settings: SettingsStore

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(TerminalTheme.all) { theme in
                    ThemeCardView(
                        theme: theme,
                        isSelected: settings.settings.themeID == theme.id
                    ) {
                        Haptics.select()
                        settings.settings.themeID = theme.id
                    }
                }
            }
            .padding(16)
        }
        .background(Color.terminalSurface.ignoresSafeArea())
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Mini terminal mock: two sample lines in the theme's foreground,
/// a cursor block in the theme's cursor color.
private struct ThemeCardView: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("$ top")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.foreground)
                HStack(spacing: 4) {
                    Text(">")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.foreground.opacity(0.65))
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(theme.cursor)
                        .frame(width: 7, height: 11)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? Color.terminalAccent : Color.white.opacity(0.08),
                        lineWidth: isSelected ? 2 : 1
                    )
            }

            Text(theme.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? Color.terminalAccent : .primary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

extension TerminalTheme {
    /// Short user-facing name derived from the identifier.
    var displayName: String {
        switch id {
        case "pro": return "Pro"
        case "homebrew": return "Homebrew"
        case "graphite": return "Graphite"
        case "paper": return "Paper"
        default: return id.capitalized
        }
    }
}
