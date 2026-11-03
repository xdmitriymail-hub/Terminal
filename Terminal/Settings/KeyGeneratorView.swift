import SwiftUI
import CryptoKit

/// Sheet that mints a new key and stores it in the vault-backed
/// keys store. `onCreated` lets embedding flows (e.g. adding a
/// server) consume the result directly.
struct KeyGeneratorView: View {
    var onCreated: ((StoredSSHKey) -> Void)? = nil

    @EnvironmentObject private var keys: KeysStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type = StoredSSHKey.KeyType.ed25519
    @State private var requireBiometry = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }

                Section {
                    Picker("Type", selection: $type) {
                        Text("ED25519").tag(StoredSSHKey.KeyType.ed25519)
                        Text("P-256").tag(StoredSSHKey.KeyType.p256)
                        Text("P-384").tag(StoredSSHKey.KeyType.p384)
                        Text("P-521").tag(StoredSSHKey.KeyType.p521)
                        if SecureEnclave.isAvailable {
                            Text("Secure Enclave").tag(StoredSSHKey.KeyType.secureEnclaveP256)
                        }
                    }
                }

                if BiometricGate.available {
                    Section {
                        Toggle(isOn: $requireBiometry) {
                            Label("Require Face ID / Touch ID", systemImage: "faceid")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.terminalSurface.ignoresSafeArea())
            .tint(.terminalAccent)
            .navigationTitle("New Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert(errorMessage ?? "", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let key = try KeyVault.generate(
                type,
                name: trimmed.isEmpty ? "Key" : trimmed,
                biometry: requireBiometry
            )
            // A failed write keeps the sheet open — the keychain entry
            // was made but nothing landed in the store.
            guard keys.save(key) else {
                errorMessage = String(localized: "Couldn't save")
                Haptics.failed()
                return
            }
            Haptics.connected()
            onCreated?(key)
            dismiss()
        } catch {
            errorMessage = String(localized: "Couldn't create this key")
            Haptics.failed()
        }
    }
}
