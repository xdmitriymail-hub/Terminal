import SwiftUI

/// One-touch command pills above the terminal. Tap sends the command —
/// snippets marked auto-enter get a trailing Return. Long-press edits
/// or deletes; the trailing "+" pill adds a new one.
struct SnippetBar: View {
    private let session: TerminalSession
    @EnvironmentObject private var snippets: SnippetsStore
    @State private var adding = false
    @State private var editing: Snippet?
    @State private var deleteFailed = false

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
        .alert("Couldn't delete", isPresented: $deleteFailed) {
            Button("OK") {}
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
                .frame(minHeight: 34)
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
                if snippets.delete(snippet) {
                    Haptics.tap()
                } else {
                    deleteFailed = true
                    Haptics.failed()
                }
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
                .frame(minHeight: 34)
                .terminalGlass(cornerRadius: 16)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add snippet")
    }
}

/// Commands for the open session. A row sends the command.
/// Adding one is a labeled action, not a lone glass plus.
struct CommandsSheet: View {
    let session: TerminalSession
    @EnvironmentObject private var snippets: SnippetsStore
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

    var body: some View {
        NavigationStack {
            Group {
                if snippets.snippets.isEmpty {
                    VStack(spacing: 16) {
                        Text("No snippets")
                            .foregroundStyle(.secondary)
                        Button("New command") { adding = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.terminalAccent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(snippets.snippets) { snippet in
                        Button {
                            Haptics.select()
                            session.send(snippet.autoEnter ? snippet.command + "\n" : snippet.command)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snippet.title)
                                    .foregroundStyle(.primary)
                                Text(snippet.command)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Color.terminalSurface.ignoresSafeArea())
            .navigationTitle("Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        adding = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(String(localized: "New command"))
                }
            }
            .sheet(isPresented: $adding) {
                AddSnippetView()
            }
        }
    }
}
