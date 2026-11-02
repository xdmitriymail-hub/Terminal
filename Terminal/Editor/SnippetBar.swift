import SwiftUI

/// One-touch command pills above the terminal. Tap sends the command —
/// snippets marked auto-enter get a trailing Return. Long-press edits
/// or deletes; the trailing "+" pill adds a new one.
struct SnippetBar: View {
    private let session: TerminalSession
    @EnvironmentObject private var snippets: SnippetsStore
    @State private var adding = false
    @State private var editing: Snippet?

    init(session: TerminalSession) {
        self.session = session
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(snippets.snippets) { snippet in
                    chip(for: snippet)
                }
                addChip
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .sheet(isPresented: $adding) {
            AddSnippetView()
        }
        .sheet(item: $editing) { snippet in
            AddSnippetView(snippet: snippet)
        }
    }

    private func chip(for snippet: Snippet) -> some View {
        Button {
            Haptics.select()
            session.send(snippet.autoEnter ? snippet.command + "\n" : snippet.command)
        } label: {
            Text(snippet.title)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .terminalGlass(cornerRadius: 16)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                editing = snippet
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Haptics.tap()
                snippets.delete(snippet)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var addChip: some View {
        Button {
            Haptics.tap()
            adding = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .terminalGlass(cornerRadius: 16)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add snippet")
    }
}
