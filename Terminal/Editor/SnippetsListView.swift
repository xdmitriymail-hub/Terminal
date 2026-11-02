import SwiftUI

/// Every snippet in one place: tap to edit, swipe to delete,
/// drag to reorder. Pushed from Settings.
struct SnippetsListView: View {
    @EnvironmentObject private var snippets: SnippetsStore
    @State private var adding = false
    @State private var editing: Snippet?

    var body: some View {
        Group {
            if snippets.snippets.isEmpty {
                EmptyState(symbol: "chevron.left.forwardslash.chevron.right")
            } else {
                List {
                    ForEach(snippets.snippets) { snippet in
                        row(snippet)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.select()
                                editing = snippet
                            }
                    }
                    .onDelete(perform: delete)
                    .onMove(perform: move)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.terminalSurface.ignoresSafeArea())
        .navigationTitle("Snippets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if !snippets.snippets.isEmpty {
                        EditButton()
                    }
                    Button {
                        Haptics.tap()
                        adding = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $adding) {
            AddSnippetView()
        }
        .sheet(item: $editing) { snippet in
            AddSnippetView(snippet: snippet)
        }
    }

    private func row(_ snippet: Snippet) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.terminalAccent)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(snippet.title)
                    .font(.body)
                    .lineLimit(1)
                Text(snippet.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func delete(_ offsets: IndexSet) {
        let doomed = offsets.compactMap { snippets.snippets[safe: $0] }
        for snippet in doomed { snippets.delete(snippet) }
    }

    private func move(_ offsets: IndexSet, to destination: Int) {
        var order = snippets.snippets
        order.move(fromOffsets: offsets, toOffset: destination)
        snippets.replaceAll(order)
        Haptics.select()
    }
}
