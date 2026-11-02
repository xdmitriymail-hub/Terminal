import SwiftUI

/// Edits a profile's forwarding rules. The engine applies them
/// when the connection comes up — this view only owns the rules.
struct PortForwardsView: View {
    @EnvironmentObject private var profiles: ProfilesStore
    @EnvironmentObject private var engine: SessionEngine
    @State private var profile: ServerProfile
    @State private var adding = false

    init(profile: ServerProfile) {
        _profile = State(initialValue: profile)
    }

    private func persist() {
        profiles.save(profile)
        Task { await engine.refreshForwards(for: profile) }
    }

    var body: some View {
        Group {
            if profile.forwards.isEmpty {
                EmptyState(symbol: "point.topleft.down.curvedto.point.bottomright.up")
            } else {
                List {
                    ForEach(profile.forwards) { forward in
                        row(forward)
                    }
                    .onDelete(perform: delete)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.terminalSurface.ignoresSafeArea())
        .navigationTitle("Forwards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $adding) {
            ForwardEditorView { forward in
                profile.forwards.append(forward)
                persist()
            }
        }
    }

    private func row(_ forward: PortForward) -> some View {
        HStack(spacing: 12) {
            Image(systemName: glyph(for: forward.kind))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.terminalAccent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(":\(forward.listenPort) → \(forward.targetHost):\(forward.targetPort)")
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
            }

            Spacer()

            Toggle(isOn: enabledBinding(for: forward.id)) {
                EmptyView()
            }
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func enabledBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { profile.forwards.first { $0.id == id }?.enabled ?? false },
            set: { on in
                guard let index = profile.forwards.firstIndex(where: { $0.id == id }) else { return }
                profile.forwards[index].enabled = on
                persist()
            }
        )
    }

    private func delete(_ offsets: IndexSet) {
        profile.forwards.remove(atOffsets: offsets)
        persist()
    }

    private func glyph(for kind: PortForward.Kind) -> String {
        switch kind {
        case .local: return "arrow.right.circle"
        case .remote: return "arrow.left.circle"
        case .dynamic: return "network"
        }
    }
}

/// Sheet for a new rule: direction, listen port, target.
private struct ForwardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind = PortForward.Kind.local
    @State private var listenPort = 8080
    @State private var targetHost = "localhost"
    @State private var targetPort = 8080

    let onAdd: (PortForward) -> Void

    private var isValid: Bool {
        (1...65535).contains(listenPort)
            && (1...65535).contains(targetPort)
            && !targetHost.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        Text("Local").tag(PortForward.Kind.local)
                        Text("Remote").tag(PortForward.Kind.remote)
                        Text("Dynamic").tag(PortForward.Kind.dynamic)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    LabeledContent("Listen") {
                        TextField("8080", value: $listenPort, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                    }
                    LabeledContent("Target") {
                        TextField("localhost", text: $targetHost)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Port") {
                        TextField("8080", value: $targetPort, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.terminalSurface.ignoresSafeArea())
            .navigationTitle("Forward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(!isValid)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func add() {
        var forward = PortForward()
        forward.kind = kind
        forward.listenPort = listenPort
        forward.targetHost = targetHost.trimmingCharacters(in: .whitespaces)
        forward.targetPort = targetPort
        forward.enabled = true
        onAdd(forward)
        Haptics.tap()
        dismiss()
    }
}
