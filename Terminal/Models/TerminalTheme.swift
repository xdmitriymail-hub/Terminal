import SwiftUI

struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let background: Color
    let foreground: Color
    let cursor: Color
    let selection: Color

    var uiBackground: UIColor { UIColor(background) }
    var uiForeground: UIColor { UIColor(foreground) }
    var uiCursor: UIColor { UIColor(cursor) }

    static let pro = TerminalTheme(
        id: "pro",
        background: Color(red: 0.05, green: 0.05, blue: 0.06),
        foreground: Color(red: 0.93, green: 0.93, blue: 0.94),
        cursor: Color(red: 0.19, green: 0.82, blue: 0.35),
        selection: Color(red: 0.24, green: 0.27, blue: 0.33)
    )

    static let homebrew = TerminalTheme(
        id: "homebrew",
        background: .black,
        foreground: Color(red: 0.16, green: 1.0, blue: 0.16),
        cursor: Color(red: 0.16, green: 1.0, blue: 0.16),
        selection: Color(red: 0.10, green: 0.30, blue: 0.10)
    )

    static let graphite = TerminalTheme(
        id: "graphite",
        background: Color(red: 0.11, green: 0.12, blue: 0.14),
        foreground: Color(red: 0.80, green: 0.83, blue: 0.88),
        cursor: Color(red: 0.39, green: 0.62, blue: 1.0),
        selection: Color(red: 0.22, green: 0.25, blue: 0.32)
    )

    static let paper = TerminalTheme(
        id: "paper",
        background: Color(red: 0.98, green: 0.98, blue: 0.97),
        foreground: Color(red: 0.13, green: 0.13, blue: 0.15),
        cursor: Color(red: 0.0, green: 0.48, blue: 1.0),
        selection: Color(red: 0.80, green: 0.86, blue: 0.98)
    )

    static let all: [TerminalTheme] = [.pro, .homebrew, .graphite, .paper]

    static func theme(id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? .pro
    }
}
