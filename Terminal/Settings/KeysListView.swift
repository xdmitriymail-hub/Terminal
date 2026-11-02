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
                        .background(.white.opacity(0.08), in: Capsule())
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
        for index in offsets {
            keys.delete(keys.keys[index])
        }
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
                            .background(.white.opacity(0.08), in: Capsule())
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

                    Text(Self.publicKeyBody(key.publicKeyOpenSSH))
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
                                exportPrivate()
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
                            .background(.white.opacity(0.1), in: Circle())
                    }
                }
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
                Haptics.failed()
                return
            }
            do {
                exportedPEM = try KeyVault.exportPrivateKey(key)
            } catch {
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
    @State private var failed = false

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
                                if failed {
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
            }
            .scrollContentBackground(.hidden)
            .background(Color.terminalSurface.ignoresSafeArea())
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: pem) { _, _ in failed = false }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(!canAdd)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        do {
            let key = try KeyVault.`import`(
                pem: pem,
                name: name.trimmingCharacters(in: .whitespaces),
                passphrase: passphrase.isEmpty ? nil : passphrase
            )
            keys.save(key)
            Haptics.connected()
            dismiss()
        } catch {
            failed = true
            Haptics.failed()
        }
    }
}
