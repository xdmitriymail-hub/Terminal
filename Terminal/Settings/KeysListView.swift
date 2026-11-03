import SwiftUI

/// Stored keys: list, detail with share/export, generate, import.
/// Errors are never text — a red glyph and a haptic.
struct KeysListView: View {
    @EnvironmentObject private var keys: KeysStore
    @State private var showGenerator = false
    @State private var showImport = false
    @State private var selected: StoredSSHKey?
    @State private var deleteFailed = false
    @State private var pendingDelete: IndexSet?

    var body: some View {
        Group {
            if keys.keys.isEmpty {
                VStack {
                    EmptyState(symbol: "key", text: String(localized: "No keys"))
                    Button("New Key") {
                        Haptics.tap()
                        showGenerator = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.terminalAccent)
                    .padding(.bottom, 24)
                }
            } else {
                List {
                    ForEach(keys.keys) { key in
                        Button {
                            Haptics.select()
                            selected = key
                        } label: {
                            row(key)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in pendingDelete = offsets }
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
                    .accessibilityLabel("Import")
                    Button {
                        Haptics.tap()
                        showGenerator = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Key")
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
        .alert("Couldn't delete", isPresented: $deleteFailed) {
            Button("OK") {}
        }
        .alert(
            "Delete \(pendingDelete?.first.flatMap { keys.keys[safe: $0] }?.name ?? "")?",
            isPresented: deletePresented
        ) {
            Button("Delete", role: .destructive) {
                if let offsets = pendingDelete { delete(offsets) }
            }
            Button("Cancel", role: .cancel) {}
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

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func delete(_ offsets: IndexSet) {
        // Snapshot first — each delete mutates the array and shifts
        // the indexes the remaining offsets point at. The store
        // persists the metadata removal BEFORE dropping the Keychain
        // secret, and reports the outcome.
        let doomed = offsets.compactMap { keys.keys[safe: $0] }
        var failed = false
        for key in doomed where !keys.delete(key) { failed = true }
        if failed {
            deleteFailed = true
            Haptics.failed()
        }
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
    /// Temp `.key` file handed to the share sheet — the PEM never
    /// travels as plain text.
    @State private var exportedURL: URL?
    @State private var showExportSheet = false
    @State private var exportPassphrase = ""
    @State private var exportFailed = false
    @State private var exporting = false
    @State private var confirmPlainExport = false
    /// Owned so Cancel can stop the vault work — and await it — before
    /// the sheet goes away.
    @State private var exportTask: Task<Void, Never>?

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

                    // The complete "type base64" line — anything less
                    // fails when pasted into authorized_keys.
                    Text(key.publicKeyOpenSSH)
                        .font(.system(.caption, design: .monospaced))
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
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close")
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
                            Button("Cancel") { closeExportSheet() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            if exporting {
                                ProgressView()
                            } else {
                                Button("Export") { exportTapped() }
                            }
                        }
                    }
                }
                .interactiveDismissDisabled(exporting)
                .presentationDetents([.medium, .large])
                // Plaintext export only ever behind this explicit step.
                .alert("Export without a passphrase?", isPresented: $confirmPlainExport) {
                    Button("Export", role: .destructive) { startExport() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The file will contain the unencrypted private key.")
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { exportedURL != nil },
                    set: { if !$0 { finishShare() } }
                )
            ) {
                if let url = exportedURL {
                    ShareSheet(items: [url]) {
                        // The temp copy served its purpose once the
                        // share completes.
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            .onDisappear {
                exportTask?.cancel()
                exportTask = nil
                if let url = exportedURL {
                    try? FileManager.default.removeItem(at: url)
                    exportedURL = nil
                }
            }
        }
    }

    private func pill(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .terminalGlass(cornerRadius: 14)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func exportTapped() {
        // No passphrase means plaintext — that needs one explicit yes.
        if exportPassphrase.isEmpty {
            confirmPlainExport = true
        } else {
            startExport()
        }
    }

    private func startExport() {
        // Snapshot now — the field is cleared the moment the share
        // sheet closes, possibly while this task still runs.
        let passphrase = exportPassphrase.isEmpty ? nil : exportPassphrase
        exporting = true
        exportFailed = false
        exportTask = Task {
            guard await BiometricGate.evaluate(key.name) else {
                exporting = false
                exportFailed = true
                Haptics.failed()
                return
            }
            do {
                try Task.checkCancellation()
                let pem = try await KeyVault.exportPrivateKey(key, passphrase: passphrase)
                try Task.checkCancellation()
                let url = try writeExport(pem)
                exporting = false
                exportedURL = url
                showExportSheet = false
            } catch is CancellationError {
                exporting = false
            } catch {
                exporting = false
                exportFailed = true
                Haptics.failed()
            }
        }
    }

    /// Cancel stops the vault work and the sheet only leaves once the
    /// task is really done — no PEM write can land after dismissal.
    private func closeExportSheet() {
        guard let task = exportTask else {
            showExportSheet = false
            return
        }
        exportTask = nil
        task.cancel()
        Task {
            _ = await task.value
            showExportSheet = false
        }
    }

    /// Private material exports as a file, never as shared text.
    private func writeExport(_ pem: String) throws -> URL {
        var safe = key.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if safe.isEmpty { safe = "key" }
        safe = safe.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safe)
            .appendingPathExtension("key")
        try Data(pem.utf8).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        return url
    }

    /// Share sheet closed: drop the temp file and both secrets held in
    /// state so nothing sensitive lingers.
    private func finishShare() {
        if let exportedURL {
            try? FileManager.default.removeItem(at: exportedURL)
        }
        exportedURL = nil
        exportPassphrase = ""
        exportTask = nil
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
                // A failed write keeps the form open — the key is in
                // the keychain but wasn't persisted to the store.
                guard keys.save(key) else {
                    importing = false
                    failure = String(localized: "Couldn't save")
                    Haptics.failed()
                    return
                }
                Haptics.connected()
                dismiss()
            } catch {
                importing = false
                failure = (error as? SSHKeyImportError).map(Self.describe)
                    ?? String(localized: "Couldn't read this key")
                Haptics.failed()
            }
        }
    }

    private static func describe(_ error: SSHKeyImportError) -> String {
        switch error {
        case .invalidFormat: return String(localized: "Not an OpenSSH private key")
        case .encryptedNeedsPassphrase: return String(localized: "This key needs its passphrase")
        case .wrongPassphrase: return String(localized: "Wrong passphrase")
        case .unsupportedCipher(let c): return String(localized: "Unsupported cipher: \(c)")
        case .unsupportedKDF(let k): return String(localized: "Unsupported KDF: \(k)")
        case .unsupportedKeyType(let t): return String(localized: "Unsupported key type: \(t)")
        case .corrupt: return String(localized: "The key material is corrupt")
        }
    }
}
