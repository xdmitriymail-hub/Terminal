import SwiftUI

/// Theme gallery: each option is a miniature terminal mock —
/// real colors, no descriptions. Accent ring marks the pick.
struct ThemePickerView: View {
    @EnvironmentObject private var settings: SettingsStore

    /// Two columns on a phone, more in landscape or on iPad.
    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                AutoThemeCard(isSelected: settings.settings.themeID == "auto") {
                    Haptics.select()
                    settings.settings.themeID = "auto"
                }
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
        Button(action: onTap) {
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
                            isSelected ? Color.terminalAccent : Color.primary.opacity(0.08),
                            lineWidth: isSelected ? 2 : 1
                        )
                }

                Text(theme.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isSelected ? Color.terminalAccent : .primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(theme.displayName)
    }
}

/// "Match system" card: half dark, half light — follows iOS appearance.
private struct AutoThemeCard: View {
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    mini(.pro)
                    mini(.paper)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isSelected ? Color.terminalAccent : Color.primary.opacity(0.08),
                            lineWidth: isSelected ? 2 : 1
                        )
                }

                Text("Auto")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isSelected ? Color.terminalAccent : .primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("Auto")
    }

    private func mini(_ theme: TerminalTheme) -> some View {
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
    }
}

extension TerminalTheme {
    /// Short user-facing name derived from the identifier.
    var displayName: String {
        switch id {
        case "pro": return String(localized: "Pro")
        case "homebrew": return String(localized: "Homebrew")
        case "graphite": return String(localized: "Graphite")
        case "paper": return String(localized: "Paper")
        default: return id.capitalized
        }
    }
}
