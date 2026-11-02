import SwiftUI
import SwiftTerm

/// SwiftTerm surface bound to a TerminalSession: bytes in → render,
/// keystrokes out → SSH channel.
struct TerminalSurface: UIViewRepresentable {
    let session: TerminalSession
    var fontSize: Double
    var theme: TerminalTheme
    var accessory: UIView?

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        applyStyle(view)
        view.terminalDelegate = context.coordinator
        view.inputAccessoryView = accessory
        view.backgroundColor = theme.uiBackground
        context.coordinator.attach(session: session, view: view)
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        applyStyle(view)
        view.inputAccessoryView = accessory
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func applyStyle(_ view: TerminalView) {
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.nativeBackgroundColor = theme.uiBackground
        view.nativeForegroundColor = theme.uiForeground
        view.caretColor = theme.uiCursor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        private weak var session: TerminalSession?
        private weak var view: TerminalView?

        func attach(session: TerminalSession, view: TerminalView) {
            self.session = session
            self.view = view
            session.onOutput = { [weak view] bytes in
                view?.feed(byteArray: bytes)
            }
        }

        func detach() {
            session?.onOutput = nil
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
            session?.send(data)
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), url.scheme == "http" || url.scheme == "https" else { return }
            UIApplication.shared.open(url)
        }

        func bell(source: TerminalView) {
            Haptics.bell()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
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
