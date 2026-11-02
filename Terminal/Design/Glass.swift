import SwiftUI

/// Liquid Glass on iOS 26; ultra-thin material fallback everywhere else.
/// Compiles on any SDK — glass API is referenced only where it exists.
struct TerminalGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 20
    var interactive = false

    func body(content: Content) -> some View {
        #if swift(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    interactive
                        ? .regular.interactive()
                        : .regular,
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        #else
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #endif
    }
}

extension View {
    func terminalGlass(cornerRadius: CGFloat = 20, interactive: Bool = false) -> some View {
        modifier(TerminalGlassModifier(cornerRadius: cornerRadius, interactive: interactive))
    }
}

extension Color {
    static let terminalAccent = Color(red: 0.19, green: 0.82, blue: 0.35)
    /// App chrome background — follows the interface style.
    static let terminalSurface = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
            : UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)
    })
    /// Raised surfaces (cards, chips) — follows the interface style.
    static let terminalElevated = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.11, alpha: 1)
            : UIColor.white
    })
}
