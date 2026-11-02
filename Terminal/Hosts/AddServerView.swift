import SwiftUI

/// New/edit server sheet. Dark grouped form, one accent, no noise.
struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var profiles: ProfilesStore
    @EnvironmentObject var keys: KeysStore
    @EnvironmentObject var engine: SessionEngine

    private let isEditing: Bool

    @State private var draft: ServerProfile
    @State private var quick = ""
    @State private var password = ""
    @State private var useKey: Bool
    @State private var selectedKeyID: UUID?
    @State private var showKeyGen = false
    @State private var keyIDsBefore: Set<UUID> = []

    init(profile: ServerProfile? = nil) {
        isEditing = profile != nil
        let d = profile ?? ServerProfile()
        _draft = State(initialValue: d)
        _useKey = State(initialValue: d.auth.usesKey)
        if case .key(let id) = d.auth {
            _selectedKeyID = State(initialValue: id)
        }
    }

    private var valid: Bool {
        !draft.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.username.trimmingCharacters(in: .whitespaces).isEmpty
            && (!useKey || selectedKeyID != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("user@host", text: $quick)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit(applyQuick)
                }

                Section {
                    TextField("Name", text: $draft.name)
                    TextField("Host", text: $draft.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", value: $draft.port, format: .number)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("Sign In", selection: $useKey) {
                        Text("Password").tag(false)
                        Text("Key").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: useKey) { _, on in
                        if on && selectedKeyID == nil {
                            selectedKeyID = keys.keys.first?.id
                        }
                    }

                    if useKey {
                        if !keys.keys.isEmpty {
                            Picker("Key", selection: $selectedKeyID) {
                                ForEach(keys.keys) { key in
                                    Text(key.name.isEmpty ? "Key" : key.name)
                                        .tag(Optional(key.id))
                                }
                            }
                        }
                        Button {
                            Haptics.tap()
                            keyIDsBefore = Set(keys.keys.map(\.id))
                            showKeyGen = true
                        } label: {
                            Label("New Key", systemImage: "plus")
                        }
                    } else {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    }
                }

                Section {
                    Picker("Via", selection: $draft.jumpProfileID) {
                        Text("None").tag(Optional<UUID>.none)
                        ForEach(profiles.profiles.filter { $0.id != draft.id }) { p in
                            Text(p.displayName).tag(Optional(p.id))
                        }
                    }
                    Toggle("Session persists", isOn: $draft.autoTmux)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .tint(.terminalAccent)
            .navigationTitle(isEditing ? "Edit" : "New Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Haptics.tap()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!valid)
                }
            }
            .sheet(isPresented: $showKeyGen, onDismiss: adoptNewKey) {
                KeyGeneratorView()
            }
        }
    }

    // MARK: - Quick connect line

    /// "ssh -p 2222 me@box" fills the form; the line is consumed once applied.
    private func applyQuick() {
        guard !quick.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let parsed = QuickConnectParser.parse(quick, profiles: profiles.profiles) else {
            return
        }
        draft.host = parsed.profile.host
        draft.port = parsed.profile.port
        draft.username = parsed.profile.username
        if let pw = parsed.password {
            password = pw
            useKey = false
        }
        Haptics.select()
        quick = ""
    }

    /// A key created in KeyGeneratorView lands in KeysStore — pick it up.
    private func adoptNewKey() {
        guard let fresh = keys.keys.first(where: { !keyIDsBefore.contains($0.id) }) else { return }
        selectedKeyID = fresh.id
        useKey = true
    }

    // MARK: - Save

    private func save() {
        applyQuick()
        draft.host = draft.host.trimmingCharacters(in: .whitespaces)
        draft.username = draft.username.trimmingCharacters(in: .whitespaces)
        if !(1...65535).contains(draft.port) { draft.port = 22 }

        guard valid else {
            Haptics.failed()
            return
        }

        if useKey {
            guard let selectedKeyID else {
                Haptics.failed()
                return
            }
            draft.auth = .key(selectedKeyID)
            // A stored password would linger unused — drop it.
            Keychain.delete("password.\(draft.id.uuidString)")
        } else {
            draft.auth = .password
            if !password.isEmpty {
                Keychain.save(password, tag: "password.\(draft.id.uuidString)")
            }
        }

        profiles.save(draft)
        // Edited host/auth must not keep a stale pooled transport or a
        // warm SFTP channel pointing at the old endpoint.
        engine.invalidateConnection(for: draft.id)
        FileBrowserViewModel.evictWarm(profileID: draft.id)
        Haptics.tap()
        dismiss()
    }
}

struct AddServerView_Previews: PreviewProvider {
    static var previews: some View {
        AddServerView()
            .environmentObject(ProfilesStore())
            .environmentObject(KeysStore())
    }
}
