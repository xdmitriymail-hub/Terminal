import Runestone
import SwiftUI
import UIKit

/// Code editor surface over Runestone's `TextView`.
///
/// Dark-only, line numbers, monospace, no autocorrection.
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
        textView.keyboardAppearance = .dark
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

/// Dark editor palette — a near-black Xcode-style surface.
private final class TerminalEditorTheme: Theme {
    let backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1) // #0D0D0F
    let font: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    let textColor = UIColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)
    let gutterBackgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
    let gutterHairlineColor = UIColor.white.withAlphaComponent(0.06)
    let lineNumberColor = UIColor.white.withAlphaComponent(0.28)
    let lineNumberFont: UIFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    let selectedLineBackgroundColor = UIColor.white.withAlphaComponent(0.05)
    let selectedLinesLineNumberColor = UIColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)
    let selectedLinesGutterBackgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
    let invisibleCharactersColor = UIColor.white.withAlphaComponent(0.2)
    let pageGuideHairlineColor = UIColor.white.withAlphaComponent(0.1)
    let pageGuideBackgroundColor = UIColor.white.withAlphaComponent(0.04)
    let markedTextBackgroundColor = UIColor.white.withAlphaComponent(0.1)

    // Unused while the editor runs in plain-text mode, but keeps the
    // theme complete should a tree-sitter language ever be attached.
    func textColor(for highlightName: String) -> UIColor? {
        switch highlightName {
        case "comment":
            return UIColor(red: 0.47, green: 0.78, blue: 0.51, alpha: 1)
        case "keyword", "constant.builtin", "variable.builtin":
            return UIColor(red: 0.99, green: 0.39, blue: 0.58, alpha: 1)
        case "string", "constant.character":
            return UIColor(red: 0.99, green: 0.55, blue: 0.40, alpha: 1)
        case "number":
            return UIColor(red: 0.85, green: 0.76, blue: 0.45, alpha: 1)
        case "type", "constructor":
            return UIColor(red: 0.58, green: 0.86, blue: 0.99, alpha: 1)
        case "function", "property":
            return UIColor(red: 0.44, green: 0.76, blue: 0.96, alpha: 1)
        case "operator", "punctuation":
            return UIColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)
        default:
            return nil
        }
    }
}
