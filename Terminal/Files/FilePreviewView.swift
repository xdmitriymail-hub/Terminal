import Foundation
import SwiftUI
import UIKit

/// In-place file preview: text opens in the code editor, images get
/// pinch-to-zoom, anything else offers the system share sheet.
struct FilePreviewView: View {
    let file: RemoteFile
    let vm: FileBrowserViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var content: Content = .binary
    @State private var text = ""
    @State private var savedText = ""
    @State private var image: UIImage?
    @State private var data: Data?
    @State private var shareItem: ShareItem?
    @State private var preparingShare = false
    @State private var saving = false
    @State private var saveFailed = false
    @State private var shareFailed = false
    @State private var confirmDiscard = false

    private enum Phase { case loading, ready, failed }
    private enum Content { case text, image, binary }

    /// Largest file we hold in memory for preview — bigger files go
    /// straight to the share flow and download on demand instead.
    private let byteCap = 6_000_000

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    failedView
                case .ready:
                    readyView
                }
            }
            .background(Color.terminalSurface.ignoresSafeArea())
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .interactiveDismissDisabled(isDirty)
            .confirmationDialog(
                "Discard changes?",
                isPresented: $confirmDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .alert("Couldn't save", isPresented: $saveFailed) {
                Button("OK") {}
            }
            .alert("Couldn't share", isPresented: $shareFailed) {
                Button("OK") {}
            }
            .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
        }
        .task { await load() }
    }

    // MARK: - Content

    @ViewBuilder
    private var readyView: some View {
        switch content {
        case .text:
            EditorView(text: $text)
        case .image:
            if let image {
                ZoomableImage(image: image)
            }
        case .binary:
            binaryView
        }
    }

    private var binaryView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(.secondary)
            if preparingShare {
                ProgressView()
            } else {
                Button {
                    Task { await share() }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.terminalAccent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failedView: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Couldn't open this file")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try Again") {
                Haptics.tap()
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.terminalAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done") { close() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if phase == .ready && content == .text {
                if saving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!isDirty)
                }
            }
        }
    }

    private var isDirty: Bool {
        content == .text && phase == .ready && text != savedText
    }

    private func close() {
        if isDirty {
            confirmDiscard = true
        } else {
            dismiss()
        }
    }

    // MARK: - Loading

    private func load() async {
        phase = .loading
        do {
            if let size = file.size, size > UInt64(byteCap) {
                content = .binary
                phase = .ready
                return
            }
            let svc = try await vm.service()
            let raw = try await svc.readFile(path: file.path, maxBytes: byteCap)
            // Never edit a possibly truncated file — a save would
            // silently cut it on the server.
            let truncated = raw.count >= byteCap && (file.size ?? UInt64(byteCap + 1)) > UInt64(raw.count)
            if truncated {
                data = raw
                content = .binary
                phase = .ready
                return
            }
            if let decoded = String(data: raw, encoding: .utf8) {
                text = decoded
                savedText = decoded
                content = .text
            } else if let decoded = UIImage(data: raw) {
                image = decoded
                content = .image
            } else {
                data = raw
                content = .binary
            }
            phase = .ready
        } catch {
            phase = .failed
            Haptics.failed()
        }
    }

    private func save() async {
        guard isDirty, !saving else { return }
        saving = true
        do {
            let svc = try await vm.service()
            try await svc.writeFile(path: file.path, data: Data(text.utf8))
            savedText = text
            Haptics.tap()
        } catch {
            saveFailed = true
            Haptics.failed()
        }
        saving = false
    }

    /// Share needs a real file URL — use what we already read, or fetch
    /// it on demand when the file was too big to keep in memory.
    private func share() async {
        guard !preparingShare else { return }
        preparingShare = true
        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("preview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Server-controlled name — flatten any path components.
            var safe = (file.name as NSString).lastPathComponent.replacingOccurrences(of: "..", with: "_")
            if safe.isEmpty { safe = "file" }
            let target = folder.appendingPathComponent(safe)
            if let data {
                try data.write(to: target, options: .atomic)
            } else {
                let svc = try await vm.service()
                try await svc.download(path: file.path, to: target, totalSize: file.size, progress: nil)
            }
            shareItem = ShareItem(url: target)
            Haptics.tap()
        } catch {
            shareFailed = true
            Haptics.failed()
        }
        preparingShare = false
    }
}

/// Pinch-to-zoom image with double-tap toggle; scrollable while zoomed.
private struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width * scale)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(magnify)
                    .onTapGesture(count: 2, perform: toggleZoom)
            }
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = lastScale * value.magnification
            }
            .onEnded { _ in
                lastScale = min(max(scale, 1), 6)
                withAnimation(.spring(duration: 0.25)) {
                    scale = lastScale
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.spring(duration: 0.3)) {
            scale = scale > 1.01 ? 1 : 2.5
            lastScale = scale
        }
    }
}

/// System share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
