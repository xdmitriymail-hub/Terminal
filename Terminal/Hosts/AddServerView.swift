import SwiftUI

/// New/edit server sheet. Dark grouped form, one accent, no noise.
struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var profiles: ProfilesStore
    @EnvironmentObject var keys: KeysStore
    @EnvironmentObject var engine: SessionEngine

    private let isEditing: Bool

    @State private var draft: ServerProfile
    @State private var password = ""
    @State private var useKey: Bool
    @State private var selectedKeyID: UUID?
    @State private var showKeyGen = false
    @State private var keyIDsBefore: Set<UUID> = []
    @State private var errorMessage: String?

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
                Section("Server") {
                    TextField("Name", text: $draft.name)
                    TextField("Address", text: $draft.host)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", value: $draft.port, format: .number)
                        .keyboardType(.numberPad)
                }

                Section("Sign In") {
                    TextField("Username", text: $draft.username)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

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
                                    Text(key.name.isEmpty ? String(localized: "Key") : key.name)
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
                    Picker("Connect through", selection: $draft.jumpProfileID) {
                        Text("Directly").tag(Optional<UUID>.none)
                        ForEach(profiles.profiles.filter { $0.id != draft.id }) { p in
                            Text(p.displayName).tag(Optional(p.id))
                        }
                    }
                    Toggle("Resume session", isOn: $draft.autoTmux)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("“Connect through” opens this server via another saved server — for machines that aren't reachable directly.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .tint(.terminalAccent)
            .navigationTitle(isEditing ? String(localized: "Edit") : String(localized: "New Server"))
            .alert(errorMessage ?? "", isPresented: errorPresented) {
                Button("OK") { errorMessage = nil }
            }
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

    /// A key created in KeyGeneratorView lands in KeysStore — pick it up.
    private func adoptNewKey() {
        guard let fresh = keys.keys.first(where: { !keyIDsBefore.contains($0.id) }) else { return }
        selectedKeyID = fresh.id
        useKey = true
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: - Save

    private func save() {
        draft.host = draft.host.trimmingCharacters(in: .whitespaces)
        draft.username = draft.username.trimmingCharacters(in: .whitespaces)

        guard valid else {
            Haptics.failed()
            return
        }
        // Never silently rewrite a port: 0 or 70000 saved as 22 looks
        // fine in the list and then refuses every connect for a reason
        // nobody can see.
        guard (1...65535).contains(draft.port) else {
            Haptics.failed()
            errorMessage = String(localized: "Port must be 1–65535")
            return
        }

        let newAuth: ServerProfile.AuthMethod
        if useKey {
            guard let selectedKeyID else {
                Haptics.failed()
                return
            }
            newAuth = .key(selectedKeyID)
        } else {
            newAuth = .password
            if !password.isEmpty {
                // Keep the form open when the secret can't be stored —
                // saving without it would lock the user out next time.
                guard Keychain.save(password, tag: "password.\(draft.id.uuidString)") == errSecSuccess else {
                    Haptics.failed()
                    errorMessage = String(localized: "Couldn't reach the keychain")
                    return
                }
            }
        }
        draft.auth = newAuth

        // Commit the profile first — only then is it safe to drop a
        // now-unused stored password.
        guard profiles.save(draft) else {
            Haptics.failed()
            errorMessage = String(localized: "Couldn't save the server")
            return
        }
        if case .key = newAuth {
            Keychain.delete("password.\(draft.id.uuidString)")
        }

        // Edited host/auth must not keep a stale pooled transport or a
        // warm SFTP channel pointing at the old endpoint — open tabs
        // retarget the freshly built connection instead of dialling
        // the values they were opened with.
        engine.retargetSessions(for: draft)
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
