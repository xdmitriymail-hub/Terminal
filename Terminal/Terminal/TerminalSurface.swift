import SwiftUI
import SwiftTerm

/// SwiftTerm surface bound to a TerminalSession: bytes in → render,
/// keystrokes out → SSH channel.
struct TerminalSurface: UIViewRepresentable {
    let session: TerminalSession
    var fontSize: Double
    var theme: TerminalTheme
    var accessory: UIView?
    /// Sticky Ctrl/Alt from the accessory bar — applies to typed keys.
    var modifiers: ModifierState?
    /// Inactive tabs must not hold the first responder — a hidden
    /// surface would keep the keyboard up over the visible one.
    var isActive = true

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        applyStyle(view)
        view.terminalDelegate = context.coordinator
        view.inputAccessoryView = accessory
        view.backgroundColor = theme.uiBackground
        context.coordinator.attach(session: session, view: view, modifiers: modifiers)
        context.coordinator.appliedStyle = Coordinator.StyleSignature(fontSize: fontSize, theme: theme)
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        // Style diffing: re-applying identical colors/font forces a full
        // glyph re-layout — skip when nothing actually changed.
        let signature = Coordinator.StyleSignature(fontSize: fontSize, theme: theme)
        if context.coordinator.appliedStyle != signature {
            applyStyle(view)
            context.coordinator.appliedStyle = signature
        }
        // reloadInputViews on an unchanged accessory steals/represents
        // the keyboard — only reload when the view actually swapped.
        if view.inputAccessoryView !== accessory {
            view.inputAccessoryView = accessory
            if view.isFirstResponder { view.reloadInputViews() }
        }
        if !isActive, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
        context.coordinator.modifiers = modifiers
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func applyStyle(_ view: TerminalView) {
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.nativeBackgroundColor = theme.uiBackground
        view.nativeForegroundColor = theme.uiForeground
        view.caretColor = theme.uiCursor
        view.backgroundColor = theme.uiBackground
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        struct StyleSignature: Equatable {
            let fontSize: Double
            let theme: TerminalTheme
        }

        private weak var session: TerminalSession?
        private weak var view: TerminalView?
        var modifiers: ModifierState?
        var appliedStyle: StyleSignature?
        private var lastBell = Date.distantPast

        func attach(session: TerminalSession, view: TerminalView, modifiers: ModifierState?) {
            self.session = session
            self.view = view
            self.modifiers = modifiers
            session.attachOutput { [weak view] bytes in
                view?.feed(byteArray: bytes)
            }
            // Hide targets THIS terminal, not whichever responder a
            // global sendAction happens to find.
            (view.inputAccessoryView as? KeyboardAccessoryView)?.onHide = { [weak view] in
                _ = view?.resignFirstResponder()
                view?.window?.endEditing(true)
            }
            // Swipe-to-dismiss on the terminal's scroll view.
            view.subviews
                .compactMap { $0 as? UIScrollView }
                .forEach { $0.keyboardDismissMode = .interactive }
        }

        func detach() {
            session?.detachOutput()
            session = nil
        }

        // MARK: TerminalViewDelegate

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session?.setSize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            session?.title = title.isEmpty ? (session?.profile.displayName ?? "") : title
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Semantic Ctrl/Alt + CR-normalization live in the session.
            session?.sendUserInput(Array(data))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), url.scheme == "http" || url.scheme == "https" else { return }
            UIApplication.shared.open(url)
        }

        func bell(source: TerminalView) {
            // A runaway `yes | xargs -I{} printf '\a'` must not hammer
            // the haptic engine — coalesce to 2 Hz.
            let now = Date()
            guard now.timeIntervalSince(lastBell) > 0.5 else { return }
            lastBell = now
            Haptics.bell()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            session?.clipboardWrite(content)
        }

        /// Remote clipboard reads are denied — an untrusted server must
        /// never be able to pull the user's pasteboard silently.
        func clipboardRead(source: TerminalView) -> Data? { nil }

        func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
            .standard
        }

        func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? {
            nil
        }

        func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? {
            nil
        }

        func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult {
            .unsupported
        }

        func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult {
            .deny
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
