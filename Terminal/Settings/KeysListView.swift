import SwiftUI

/// Stored keys: list, detail with share/export, generate, import.
/// Errors are never text — a red glyph and a haptic.
struct KeysListView: View {
    @EnvironmentObject private var keys: KeysStore
    @State private var showGenerator = false
    @State private var showImport = false
    @State private var selected: StoredSSHKey?

    var body: some View {
        Group {
            if keys.keys.isEmpty {
                EmptyState(symbol: "key")
            } else {
                List {
                    ForEach(keys.keys) { key in
                        row(key)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.select()
                                selected = key
                            }
                    }
                    .onDelete(perform: delete)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.terminalSurface.ignoresSafeArea())
        .navigationTitle("Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        Haptics.tap()
                        showImport = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Button {
                        Haptics.tap()
                        showGenerator = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showGenerator) {
            KeyGeneratorView()
        }
        .sheet(isPresented: $showImport) {
            KeyImportView()
        }
        .sheet(item: $selected) { key in
            KeyDetailView(key: key)
        }
    }

    private func row(_ key: StoredSSHKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.terminalAccent)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(key.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Self.typeLabel(key.type))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    if key.inSecureEnclave {
                        Image(systemName: "cpu")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if key.requiresBiometry {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func delete(_ offsets: IndexSet) {
        // Snapshot first — each delete mutates the array and shifts
        // the indexes the remaining offsets point at.
        let doomed = offsets.compactMap { keys.keys[safe: $0] }
        for key in doomed { keys.delete(key) }
    }

    /// The base64 body only — the wire prefix ("ssh-ed25519 …") stays
    /// in the stored/exported line but never on screen.
    static func publicKeyBody(_ line: String) -> String {
        line.split(separator: " ").dropFirst().joined(separator: " ")
    }

    static func typeLabel(_ type: StoredSSHKey.KeyType) -> String {
        switch type {
        case .ed25519: return "ED25519"
        case .p256: return "P-256"
        case .p384: return "P-384"
        case .p521: return "P-521"
        case .secureEnclaveP256: return "Secure Enclave"
        case .rsa: return "RSA"
        }
    }
}

/// Detail sheet: public key in monospace, share, and a gated
/// private-key export for exportable types.
private struct KeyDetailView: View {
    let key: StoredSSHKey

    @Environment(\.dismiss) private var dismiss
    @State private var exportedPEM: String?
    @State private var showExportSheet = false
    @State private var exportPassphrase = ""
    @State private var exportFailed = false

    private var canExport: Bool {
        !key.inSecureEnclave && key.type != .rsa
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 6) {
                        Text(KeysListView.typeLabel(key.type))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        if key.inSecureEnclave {
                            Image(systemName: "cpu")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if key.requiresBiometry {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(KeysListView.publicKeyBody(key.publicKeyOpenSSH))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .terminalGlass(cornerRadius: 14)

                    HStack(spacing: 10) {
                        ShareLink(item: key.publicKeyOpenSSH) {
                            pill("Share", symbol: "square.and.arrow.up")
                        }
                        .buttonStyle(.plain)

                        if canExport {
                            Button {
                                exportPassphrase = ""
                                exportFailed = false
                                showExportSheet = true
                            } label: {
                                pill("Export private", symbol: "lock.open")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.terminalSurface.ignoresSafeArea())
            .navigationTitle(key.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(7)
                            .background(Color.primary.opacity(0.1), in: Circle())
                    }
                }
            }
            .sheet(isPresented: $showExportSheet) {
                NavigationStack {
                    Form {
                        Section {
                            SecureField("Passphrase (optional)", text: $exportPassphrase)
                        } footer: {
                            Text("A passphrase encrypts the exported file. Without one, anyone holding the file owns the key.")
                        }
                        if exportFailed {
                            Section {
                                Text("Couldn't export this key")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.terminalSurface.ignoresSafeArea())
                    .navigationTitle("Export Private Key")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showExportSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Export") { exportPrivate() }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(
                isPresented: Binding(
                    get: { exportedPEM != nil },
                    set: { if !$0 { exportedPEM = nil } }
                )
            ) {
                if let pem = exportedPEM {
                    ShareLink(item: pem) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 13)
                            .terminalGlass(cornerRadius: 16)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.terminalSurface.ignoresSafeArea())
                    .presentationDetents([.height(160)])
                }
            }
        }
    }

    private func pill(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .terminalGlass(cornerRadius: 14)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func exportPrivate() {
        Task {
            guard await BiometricGate.evaluate(key.name) else {
                exportFailed = true
                Haptics.failed()
                return
            }
            do {
                exportedPEM = try KeyVault.exportPrivateKey(
                    key,
                    passphrase: exportPassphrase.isEmpty ? nil : exportPassphrase
                )
                showExportSheet = false
            } catch {
                exportFailed = true
                Haptics.failed()
            }
        }
    }
}

/// Paste-in import: PEM editor, passphrase only when the pasted
/// material actually needs it.
private struct KeyImportView: View {
    @EnvironmentObject private var keys: KeysStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var pem = ""
    @State private var passphrase = ""
    @State private var failure: String?
    @State private var importing = false

    private var encrypted: Bool {
        OpenSSHKeyParser.isEncrypted(pem)
    }

    private var canAdd: Bool {
        !pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!encrypted || !passphrase.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }

                Section {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $pem)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 150)
                            .scrollContentBackground(.hidden)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .overlay(alignment: .topTrailing) {
                                if failure != nil {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                        .padding(6)
                                }
                            }
                        if pem.isEmpty {
                            Text("Paste")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 9)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                }

                if encrypted {
                    Section {
                        SecureField("Passphrase", text: $passphrase)
                    }
                }

                if let failure {
                    Section {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.terminalSurface.ignoresSafeArea())
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: pem) { _, _ in failure = nil }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if importing {
                        ProgressView()
                    } else {
                        Button("Add") { add() }
                            .disabled(!canAdd)
                    }
                }
            }
            .interactiveDismissDisabled(importing)
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        // bcrypt KDF on an encrypted key can run for seconds — never
        // on the main actor.
        let pem = self.pem
        let name = self.name.trimmingCharacters(in: .whitespaces)
        let passphrase = self.passphrase.isEmpty ? nil : self.passphrase
        importing = true
        Task {
            do {
                let key = try await Task.detached(priority: .userInitiated) {
                    try KeyVault.`import`(pem: pem, name: name, passphrase: passphrase)
                }.value
                keys.save(key)
                Haptics.connected()
                dismiss()
            } catch {
                importing = false
                failure = (error as? SSHKeyImportError).map(Self.describe) ?? "Couldn't read this key"
                Haptics.failed()
            }
        }
    }

    private static func describe(_ error: SSHKeyImportError) -> String {
        switch error {
        case .invalidFormat: return "Not an OpenSSH private key"
        case .encryptedNeedsPassphrase: return "This key needs its passphrase"
        case .wrongPassphrase: return "Wrong passphrase"
        case .unsupportedCipher(let c): return "Unsupported cipher: \(c)"
        case .unsupportedKDF(let k): return "Unsupported KDF: \(k)"
        case .unsupportedKeyType(let t): return "Unsupported key type: \(t)"
        case .corrupt: return "The key material is corrupt"
        }
    }
}
