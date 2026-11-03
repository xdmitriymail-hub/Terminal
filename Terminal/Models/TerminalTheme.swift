import SwiftUI
import SwiftTerm

struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let background: SwiftUI.Color
    let foreground: SwiftUI.Color
    let cursor: SwiftUI.Color
    let selection: SwiftUI.Color

    var uiBackground: UIColor { UIColor(background) }
    var uiForeground: UIColor { UIColor(foreground) }
    var uiCursor: UIColor { UIColor(cursor) }

    /// The 16 ANSI colors `ls`, prompts and TUIs actually render in —
    /// without this a theme only repaints the default text, and a light
    /// theme still gets dark-mode palette values that wash out.
    var ansiColors: [SwiftTerm.Color] {
        switch id {
        case "homebrew":
            return Self.palette([
                0x1a2b1a, 0xee5b4d, 0x3bd94a, 0xd8a812, 0x4d9aee, 0xe05fd0,
                0x3fd0be, 0xa8d8a8, 0x4d7a4d, 0xff8477, 0x63f070, 0xf0cc3f,
                0x77b8ff, 0xf78fe8, 0x6ff0e0, 0xd8ffd8
            ])
        case "graphite":
            return Self.palette([
                0x23262d, 0xe06c75, 0x98c379, 0xd19a66, 0x61afef, 0xc678dd,
                0x56b6c2, 0xabb2bf, 0x5c6370, 0xef8f98, 0xb0d99a, 0xe0b885,
                0x84c4f5, 0xd896e8, 0x74ccd7, 0xd0d6e0
            ])
        case "paper":
            // Light themes need darkened ANSI values — the stock
            // palette is tuned for dark backgrounds and washes out.
            return Self.palette([
                0x2a2c30, 0xc42b2b, 0x2e8b17, 0xb05c00, 0x1a5fd7, 0xa022a0,
                0x0e7c86, 0x6a6f78, 0x9aa0aa, 0xe05555, 0x3fa322, 0xd07a1e,
                0x3a7ff0, 0xbd3dc0, 0x17a0ab, 0x3a3d42
            ])
        default: // pro — dark
            return Self.palette([
                0x26272b, 0xff6c60, 0xa8cc8c, 0xe9c062, 0x71bef2, 0xd38df0,
                0x73d8d0, 0xe8e8e8, 0x7a7f8a, 0xff9185, 0xbfe3a8, 0xf7d38b,
                0x96d0f7, 0xe0aef7, 0x96e4dd, 0xffffff
            ])
        }
    }

    private static func palette(_ hex: [Int]) -> [SwiftTerm.Color] {
        hex.map { h in
            SwiftTerm.Color(
                red8: UInt16((h >> 16) & 0xFF),
                green8: UInt16((h >> 8) & 0xFF),
                blue8: UInt16(h & 0xFF)
            )
        }
    }

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
