import Foundation
import SwiftUI
import UIKit
import ImageIO
import Citadel

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
    @State private var shareProgress: Double?
    @State private var shareTask: Task<Void, Never>?
    @State private var saving = false
    @State private var saveFailed = false
    @State private var shareFailed = false
    @State private var confirmDiscard = false
    @State private var confirmOverwrite = false
    /// Post-save remote attributes — the conflict baseline must move
    /// forward after every successful save or the next save would
    /// false-positive on our own write.
    @State private var postSaveSize: UInt64?
    @State private var postSaveMTime: Date?
    /// Bumped on every load() so a stale decode/read result can never
    /// overwrite a newer attempt.
    @State private var loadGeneration = 0
    /// Single in-flight ImageIO decode — cancelled before a retry can
    /// start a second one for the same file.
    @State private var decodeTask: Task<UIImage?, Never>?

    private enum Phase { case loading, ready, failed }
    private enum Content { case text, image, binary }

    /// Largest file we hold in memory for preview — bigger files go
    /// straight to the share flow and download on demand instead.
    private let byteCap = 6_000_000

    /// Largest text the editor takes — bigger files stay read-only
    /// through the share path instead of choking the editor.
    private let editorCap = 1_500_000

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// Remote state captured when the file was listed — the baseline
    /// external-modification checks compare against.
    private var snapshotSize: UInt64? { postSaveSize ?? file.size }
    private var snapshotMTime: Date? { postSaveMTime ?? file.modified }

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
            .confirmationDialog(
                "“\(file.name)” changed on the server",
                isPresented: $confirmOverwrite,
                titleVisibility: .visible
            ) {
                Button("Overwrite", role: .destructive) {
                    Task { await save(force: true) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't save", isPresented: $saveFailed) {
                Button("OK") {}
            }
            .alert("Couldn't share", isPresented: $shareFailed) {
                Button("OK") {}
            }
            .sheet(item: $shareItem, onDismiss: { shareItem = nil }) { item in
                ShareSheet(items: [item.url]) {
                    // Temp copy served its purpose once the sheet is gone.
                    try? FileManager.default.removeItem(
                        at: item.url.deletingLastPathComponent()
                    )
                }
            }
        }
        .task { await load() }
        .onDisappear {
            // Dropping the view abandons both the share download and
            // any pending decode work.
            shareTask?.cancel()
            decodeTask?.cancel()
        }
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
                Group {
                    if let shareProgress {
                        ProgressView(value: shareProgress)
                    } else {
                        ProgressView()
                    }
                }
                Button("Cancel", role: .cancel) {
                    shareTask?.cancel()
                }
            } else {
                Button {
                    shareTask = Task { await share() }
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
                        Task { await save(force: false) }
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
        loadGeneration += 1
        let gen = loadGeneration
        // A retry must never run two decodes at once for the same file.
        decodeTask?.cancel()
        decodeTask = nil
        phase = .loading
        do {
            if let size = file.size, size > UInt64(byteCap) {
                guard gen == loadGeneration else { return }
                content = .binary
                phase = .ready
                return
            }
            let svc = try await vm.service()
            let (raw, complete) = try await svc.readFile(path: file.path, maxBytes: byteCap)
            guard gen == loadGeneration else { return }
            // Never edit or share a possibly truncated file — saving
            // would silently cut it on the server, sharing would ship
            // a broken copy. `data` stays nil so share() downloads it
            // in full instead.
            guard complete else {
                content = .binary
                phase = .ready
                return
            }
            if raw.count <= editorCap, let decoded = String(data: raw, encoding: .utf8) {
                text = decoded
                savedText = decoded
                content = .text
            } else {
                // ImageIO decode is heavy CPU work — never on the UI
                // thread. Only the result hops back to the view, and
                // only if this load is still the current one.
                let decode = Task.detached(priority: .userInitiated) {
                    Self.downsampled(raw)
                }
                decodeTask = decode
                let decoded = await decode.value
                guard gen == loadGeneration else { return }
                if let decoded {
                    image = decoded
                    content = .image
                } else {
                    data = raw
                    content = .binary
                }
            }
            phase = .ready
        } catch {
            guard gen == loadGeneration else { return }
            phase = .failed
            Haptics.failed()
        }
    }

    // MARK: - Saving

    /// Re-stat the remote file and compare with the listing snapshot:
    /// a size or mtime change means someone else touched it since we
    /// loaded. Unverifiable stat results count as "changed" — prompting
    /// is always cheaper than a blind overwrite.
    private func isExternallyModified(using svc: SFTPService) async -> Bool {
        let attrs: SFTPFileAttributes
        do {
            attrs = try await svc.stat(path: file.path)
        } catch {
            return true
        }
        if attrs.size != snapshotSize { return true }
        let remoteMTime = attrs.accessModificationTime?.modificationTime
        if remoteMTime != snapshotMTime { return true }
        return false
    }

    private func save(force: Bool) async {
        guard isDirty, !saving else { return }
        saving = true
        // Snapshot first — edits during the await must stay dirty.
        let snapshot = text
        do {
            let svc = try await vm.service()
            if !force, await isExternallyModified(using: svc) {
                saving = false
                confirmOverwrite = true
                return
            }
            try await svc.writeFile(path: file.path, data: Data(snapshot.utf8))
            savedText = snapshot
            // Re-stat so the next save compares against the file we
            // just wrote, not the stale listing entry.
            if let after = try? await svc.stat(path: file.path) {
                postSaveSize = after.size
                postSaveMTime = after.accessModificationTime?.modificationTime
            }
            Haptics.tap()
        } catch {
            saveFailed = true
            Haptics.failed()
        }
        saving = false
    }

    // MARK: - Sharing

    /// Share needs a real file URL — stream it into a private temp
    /// folder (bounded buffer, never a whole-file Data for big files)
    /// and let the sheet's dismissal + a launch-time sweep handle
    /// cleanup. Cancel removes the half-written copy.
    private func share() async {
        guard !preparingShare else { return }
        preparingShare = true
        shareProgress = nil
        defer {
            preparingShare = false
            shareProgress = nil
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Server-controlled name — same flattening rules the
            // transfer queue applies.
            let target = folder.appendingPathComponent(TransferManager.sanitizedFileName(file.name))
            if let data {
                // Already in memory (small binary file) — a plain write
                // is cheaper than a second remote read.
                try data.write(to: target, options: .atomic)
            } else {
                try Self.requireFreeSpace(for: file.size)
                let svc = try await vm.service()
                try await svc.download(path: file.path, to: target, totalSize: file.size) { fraction in
                    Task { @MainActor in
                        self.shareProgress = fraction
                    }
                }
            }
            try Task.checkCancellation()
            shareItem = ShareItem(url: target)
            Haptics.tap()
        } catch is CancellationError {
            // Partially streamed file — drop the whole private folder.
            try? FileManager.default.removeItem(at: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            shareFailed = true
            Haptics.failed()
        }
    }

    /// Fail fast when the device clearly can't hold the download —
    /// better than discovering it mid-stream.
    private static func requireFreeSpace(for needed: UInt64?) throws {
        guard let needed else { return }
        let values = try FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values.volumeAvailableCapacityForImportantUsage, free >= 0 else { return }
        if UInt64(free) < needed {
            throw ShareFailure.insufficientSpace
        }
    }

    private enum ShareFailure: Error {
        case insufficientSpace
    }

    /// Decode huge rasters through ImageIO with a pixel cap so a 40 MP
    /// photo can't blow the memory budget. Runs on a detached worker —
    /// never the UI thread.
    private static func downsampled(_ data: Data, maxPixel: CGFloat = 4096) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        guard max(w, h) > maxPixel else { return UIImage(data: data) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }

    /// Left-over share folders from previous runs — called once at app
    /// launch so killed mid-share sessions can't accumulate secrets.
    static func purgeShareTemps() {
        let tmp = FileManager.default.temporaryDirectory
        for item in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        where item.hasPrefix("preview-") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(item))
        }
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
    var onDone: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onDone?() }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
