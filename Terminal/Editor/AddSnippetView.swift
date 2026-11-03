import SwiftUI

/// Add or edit a snippet: a title, the command itself, and whether a
/// tap should also press Return. Pass a `Snippet` to edit it.
struct AddSnippetView: View {
    @EnvironmentObject private var snippets: SnippetsStore
    @Environment(\.dismiss) private var dismiss

    private let existing: Snippet?
    @State private var title: String
    @State private var command: String
    @State private var autoEnter: Bool
    @State private var saveFailed = false

    init(snippet: Snippet? = nil) {
        existing = snippet
        _title = State(initialValue: snippet?.title ?? "")
        _command = State(initialValue: snippet?.command ?? "")
        _autoEnter = State(initialValue: snippet?.autoEnter ?? false)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .autocorrectionDisabled()
                }
                Section {
                    TextField("Command", text: $command, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1...6)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.default)
                }
                Section {
                    Toggle(isOn: $autoEnter) {
                        Label("Press Return", systemImage: "return")
                    }
                    .tint(.terminalAccent)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.terminalSurface.ignoresSafeArea())
            .navigationTitle(existing == nil ? String(localized: "New command") : String(localized: "Edit command"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert("Couldn't save", isPresented: $saveFailed) {
            Button("OK") {}
        }
    }

    private func save() {
        var snippet = existing ?? Snippet()
        snippet.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.command = command
        snippet.autoEnter = autoEnter
        // A failed write keeps the sheet open — nothing was persisted.
        guard snippets.save(snippet) else {
            saveFailed = true
            Haptics.failed()
            return
        }
        Haptics.connected()
        dismiss()
    }
}
