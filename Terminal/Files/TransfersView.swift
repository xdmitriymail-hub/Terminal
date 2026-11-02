import SwiftUI

/// Transfer queue sheet: linear progress per row, done rows dimmed
/// with a checkmark, finished rows swipe away.
struct TransfersView: View {
    @ObservedObject private var manager = TransferManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if manager.transfers.isEmpty {
                    EmptyState(symbol: "arrow.up.arrow.down", text: nil)
                } else {
                    List(manager.transfers) { transfer in
                        row(transfer)
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Color.primary.opacity(0.08))
                            .swipeActions(edge: .trailing) {
                                if transfer.state != .running {
                                    Button(role: .destructive) {
                                        manager.remove(transfer.id)
                                    } label: {
                                        Label("Remove", systemImage: "xmark")
                                    }
                                }
                            }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.terminalSurface.ignoresSafeArea())
            .navigationTitle("Transfers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if manager.transfers.contains(where: { $0.state != .running }) {
                        Button("Clear") {
                            manager.clearFinished()
                            Haptics.tap()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ transfer: TransferManager.Transfer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.isUpload ? "arrow.up" : "arrow.down")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.terminalAccent)
                .frame(width: 34, height: 34)
                .background(Color.terminalAccent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(transfer.name)
                    .font(.subheadline)
                    .lineLimit(1)
                switch transfer.state {
                case .running:
                    ProgressView(value: transfer.progress)
                        .tint(Color.terminalAccent)
                case .done:
                    Text("Done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed:
                    Text("Couldn't finish")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            switch transfer.state {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red.opacity(0.75))
            case .running:
                EmptyView()
            }
        }
        .padding(.vertical, 3)
        .opacity(transfer.state == .done ? 0.55 : 1)
    }
}
