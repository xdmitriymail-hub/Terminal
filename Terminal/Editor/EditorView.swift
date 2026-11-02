import Runestone
import SwiftUI
import UIKit

/// Code editor surface over Runestone's `TextView`.
///
/// Line numbers, monospace, no autocorrection; colors adapt to the
/// active light/dark appearance.
struct EditorView: UIViewRepresentable {
    @Binding var text: String

    init(text: Binding<String>) {
        _text = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> TextView {
        let theme = TerminalEditorTheme()
        let textView = TextView()
        textView.editorDelegate = context.coordinator
        textView.backgroundColor = theme.backgroundColor

        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .automatic
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.showLineNumbers = true
        textView.lineSelectionDisplayType = .line
        textView.lineHeightMultiplier = 1.4
        textView.isLineWrappingEnabled = true
        textView.indentStrategy = .space(length: 4)

        textView.characterPairs = [
            EditorCharacterPair(leading: "(", trailing: ")"),
            EditorCharacterPair(leading: "{", trailing: "}"),
            EditorCharacterPair(leading: "[", trailing: "]"),
            EditorCharacterPair(leading: "\"", trailing: "\""),
            EditorCharacterPair(leading: "'", trailing: "'")
        ]
        textView.characterPairTrailingComponentDeletionMode = .immediatelyFollowingLeadingComponent

        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardType = .asciiCapable
        // .default follows the interface style — dark keyboard in dark
        // mode, light in light.
        textView.keyboardAppearance = .default
        textView.returnKeyType = .default

        let accent = UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
        textView.insertionPointColor = accent
        textView.selectionBarColor = accent
        textView.selectionHighlightColor = accent.withAlphaComponent(0.25)

        textView.isFindInteractionEnabled = true
        textView.setState(TextViewState(text: text, theme: theme))
        return textView
    }

    func updateUIView(_ textView: TextView, context: Context) {
        context.coordinator.text = $text
        // Never clobber an in-progress edit; external reloads only
        // land while the view isn't editing and actually differ.
        guard !textView.isEditing, textView.text != text else { return }
        textView.text = text
    }

    final class Coordinator: NSObject, TextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: TextView) {
            guard text.wrappedValue != textView.text else { return }
            text.wrappedValue = textView.text
        }
    }
}

/// `CharacterPair` is a protocol; Runestone ships no concrete pairs.
private struct EditorCharacterPair: CharacterPair {
    let leading: String
    let trailing: String
}

/// Adaptive editor palette — Xcode-style in dark, paper in light.
/// Dynamic UIColors follow trait changes without a state rebuild.
private final class TerminalEditorTheme: Theme {
    private static func adaptive(dark: UIColor, light: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }

    let backgroundColor = adaptive(
        dark: UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1),
        light: UIColor(red: 0.99, green: 0.99, blue: 1, alpha: 1)
    )
    let font: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    let textColor = adaptive(
        dark: UIColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1),
        light: UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
    )
    let gutterBackgroundColor = adaptive(
        dark: UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1),
        light: UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    )
    let gutterHairlineColor = adaptive(
        dark: UIColor.white.withAlphaComponent(0.06),
        light: UIColor.black.withAlphaComponent(0.08)
    )
    let lineNumberColor = adaptive(
        dark: UIColor.white.withAlphaComponent(0.28),
        light: UIColor.black.withAlphaComponent(0.3)
    )
    let lineNumberFont: UIFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    let selectedLineBackgroundColor = adaptive(
        dark: UIColor.white.withAlphaComponent(0.05),
        light: UIColor.black.withAlphaComponent(0.05)
    )
    let selectedLinesLineNumberColor = adaptive(
        dark: UIColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1),
        light: UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
    )
    let selectedLinesGutterBackgroundColor = adaptive(
        dark: UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1),
        light: UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    )
    let invisibleCharactersColor = adaptive(
        dark: UIColor.white.withAlphaComponent(0.2),
        light: UIColor.black.withAlphaComponent(0.2)
    )
    let pageGuideHairlineColor = adaptive(
        dark: UIColor.white.withAlphaComponent(0.1),
        light: UIColor.black.withAlphaComponent(0.1)
    )
    let pageGuideBackgroundColor = adaptive(
        dark: UIColor.white.withAlphaComponent(0.04),
        light: UIColor.black.withAlphaComponent(0.04)
    )
    let markedTextBackgroundColor = adaptive(
        dark: UIColor.white.withAlphaComponent(0.1),
        light: UIColor.black.withAlphaComponent(0.1)
    )

    // Unused while the editor runs in plain-text mode, but keeps the
    // theme complete should a tree-sitter language ever be attached.
    func textColor(for highlightName: String) -> UIColor? {
        switch highlightName {
        case "comment":
            return Self.adaptive(
                dark: UIColor(red: 0.47, green: 0.78, blue: 0.51, alpha: 1),
                light: UIColor(red: 0.28, green: 0.55, blue: 0.32, alpha: 1)
            )
        case "keyword", "constant.builtin", "variable.builtin":
            return Self.adaptive(
                dark: UIColor(red: 0.99, green: 0.39, blue: 0.58, alpha: 1),
                light: UIColor(red: 0.72, green: 0.16, blue: 0.36, alpha: 1)
            )
        case "string", "constant.character":
            return Self.adaptive(
                dark: UIColor(red: 0.99, green: 0.55, blue: 0.40, alpha: 1),
                light: UIColor(red: 0.77, green: 0.30, blue: 0.13, alpha: 1)
            )
        case "number":
            return Self.adaptive(
                dark: UIColor(red: 0.85, green: 0.76, blue: 0.45, alpha: 1),
                light: UIColor(red: 0.55, green: 0.45, blue: 0.10, alpha: 1)
            )
        case "type", "constructor":
            return Self.adaptive(
                dark: UIColor(red: 0.58, green: 0.86, blue: 0.99, alpha: 1),
                light: UIColor(red: 0.20, green: 0.55, blue: 0.75, alpha: 1)
            )
        case "function", "property":
            return Self.adaptive(
                dark: UIColor(red: 0.44, green: 0.76, blue: 0.96, alpha: 1),
                light: UIColor(red: 0.16, green: 0.42, blue: 0.72, alpha: 1)
            )
        case "operator", "punctuation":
            return Self.adaptive(
                dark: UIColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1),
                light: UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
            )
        default:
            return nil
        }
    }
}
