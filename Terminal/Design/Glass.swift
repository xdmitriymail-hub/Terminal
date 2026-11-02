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
    static let terminalSurface = Color(red: 0.05, green: 0.05, blue: 0.06)
    static let terminalElevated = Color(white: 0.11)
}
