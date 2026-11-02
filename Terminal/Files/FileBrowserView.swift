import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Remote file browser for one profile. Pushed (or sheeted) inside a
/// NavigationStack by the caller — this view owns the breadcrumb bar,
/// the file list and all toolbars.
struct FileBrowserView: View {
    let profile: ServerProfile
    @EnvironmentObject private var engine: SessionEngine

    var body: some View {
        FileBrowserContent(profile: profile, engine: engine)
    }
}

private struct FileBrowserContent: View {
    @StateObject private var vm: FileBrowserViewModel
    @ObservedObject private var transfers = TransferManager.shared

    @State private var preview: RemoteFile?
    @State private var renaming: RemoteFile?
    @State private var renameText = ""
    @State private var deleting: RemoteFile?
    @State private var chmodTarget: RemoteFile?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showImporter = false
    @State private var showTransfers = false

    init(profile: ServerProfile, engine: SessionEngine) {
        _vm = StateObject(wrappedValue: FileBrowserViewModel(profile: profile, engine: engine))
    }

    var body: some View {
        base
            .sheet(item: $preview) { file in
                FilePreviewView(file: file, vm: vm)
            }
            .sheet(item: $chmodTarget) { file in
                PermissionsSheet(file: file) { perm in
                    Task { await vm.chmod(file: file, perm: perm) }
                }
            }
            .sheet(isPresented: $showTransfers) {
                TransfersView()
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
                handleImport(result)
            }
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Name", text: $newFolderName)
                Button("Create") {
                    Task { await vm.makeDir(name: newFolderName) }
                }
                .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename", isPresented: renamePresented, presenting: renaming) { file in
                TextField("Name", text: $renameText)
                Button("Save") {
                    Task { await vm.rename(file: file, to: renameText) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete \(deleting?.name ?? "")?", isPresented: deletePresented, presenting: deleting) { file in
                Button("Delete", role: .destructive) {
                    Task { await vm.delete(file: file) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(vm.error ?? "", isPresented: errorAlertPresented) {
                Button("OK") { vm.error = nil }
            }
    }

    private var base: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            content
        }
        .background(Color.terminalSurface.ignoresSafeArea())
        .navigationTitle(vm.profile.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $vm.searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search"
        )
        .toolbar { toolbarContent }
        .task { await vm.open() }
        .onDisappear { vm.park() }
        .onChange(of: showTransfers) { _, shown in
            // Pick up freshly uploaded files when the queue sheet closes.
            if !shown { Task { await vm.reload() } }
        }
    }

    // MARK: - Breadcrumbs

    private var breadcrumbBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(vm.breadcrumbs) { crumb in
                        if crumb.path != "/" {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        crumbButton(crumb, isLast: crumb.id == vm.breadcrumbs.last?.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onChange(of: vm.path) { _, _ in
                if let last = vm.breadcrumbs.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .trailing) }
                }
            }
        }
    }

    private func crumbButton(_ crumb: FileBrowserViewModel.Crumb, isLast: Bool) -> some View {
        Button {
            Haptics.select()
            Task { await vm.jump(to: crumb.path) }
        } label: {
            Group {
                if crumb.path == "/" {
                    Image(systemName: "server.rack")
                        .font(.caption.weight(.semibold))
                } else {
                    Text(crumb.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isLast ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .terminalGlass(cornerRadius: 11)
        }
        .buttonStyle(.plain)
        .id(crumb.id)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.files.isEmpty && vm.error == nil {
            skeleton
        } else if let message = vm.error, vm.files.isEmpty {
            errorView(message)
        } else if vm.visibleFiles.isEmpty {
            EmptyState(symbol: vm.searchText.isEmpty ? "folder" : "magnifyingglass", text: nil)
        } else {
            fileList
        }
    }

    private var fileList: some View {
        List(vm.visibleFiles) { file in
            Button {
                tap(file)
            } label: {
                row(file)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(.white.opacity(0.08))
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleting = file
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !file.isDirectory {
                    Button {
                        startDownload(file)
                    } label: {
                        Label("Download", systemImage: "arrow.down")
                    }
                    .tint(Color.terminalAccent)
                }
            }
            .contextMenu { menuItems(file) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await vm.reload() }
        .animation(.easeInOut(duration: 0.2), value: vm.path)
    }

    private func row(_ file: RemoteFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: file))
                .font(.title3)
                .foregroundStyle(file.isDirectory ? Color.terminalAccent : Color.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle(for: file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if file.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var skeleton: some View {
        List(0..<9, id: \.self) { _ in
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .frame(width: 150, height: 11)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .frame(width: 90, height: 8)
                }
            }
            .foregroundStyle(.white.opacity(0.06))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .allowsHitTesting(false)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try Again") {
                Haptics.tap()
                Task { await vm.retry() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.terminalAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                Haptics.select()
                Task { await vm.up() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!vm.canGoUp)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Haptics.tap()
                showTransfers = true
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .overlay(alignment: .topTrailing) {
                        if transfers.activeCount > 0 {
                            Text("\(transfers.activeCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(3)
                                .background(Circle().fill(Color.terminalAccent))
                                .offset(x: 8, y: -6)
                        }
                    }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Upload", systemImage: "arrow.up.doc")
                }
                Divider()
                Button {
                    Task { await vm.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    // MARK: - Actions

    private func tap(_ file: RemoteFile) {
        if file.isDirectory {
            Haptics.select()
            Task { await vm.navigate(file) }
        } else {
            Haptics.tap()
            preview = file
        }
    }

    private func startDownload(_ file: RemoteFile) {
        Haptics.tap()
        Task {
            guard let svc = try? await vm.service() else {
                vm.error = "Couldn't download"
                Haptics.failed()
                return
            }
            TransferManager.shared.download(file: file, via: svc)
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        Task {
            guard let svc = try? await vm.service() else {
                vm.error = "Couldn't upload"
                Haptics.failed()
                return
            }
            TransferManager.shared.upload(
                local: url,
                to: vm.remotePath(for: url.lastPathComponent),
                via: svc
            )
            // Let the picker finish dismissing before showing the queue.
            try? await Task.sleep(for: .milliseconds(300))
            showTransfers = true
        }
    }

    // MARK: - Helpers

    private func icon(for file: RemoteFile) -> String {
        if file.isDirectory { return "folder.fill" }
        if file.isSymlink { return "link" }
        switch (file.name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp":
            return "photo"
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar":
            return "doc.zipper"
        case "txt", "md", "json", "yml", "yaml", "xml", "html", "css",
             "sh", "zsh", "bash", "py", "rb", "js", "ts", "c", "h",
             "cpp", "swift", "conf", "cfg", "ini", "log", "csv", "env", "plist":
            return "doc.text"
        default:
            break
        }
        if Self.textFilenames.contains(file.name.lowercased()) {
            return "doc.text"
        }
        if let perms = file.permissions, perms & 0o111 != 0 {
            return "terminal"
        }
        return "doc"
    }

    /// Extensionless files that are always text (dotfiles, build files).
    private static let textFilenames: Set<String> = [
        ".bashrc", ".zshrc", ".profile", ".bash_profile", ".bash_history",
        ".vimrc", ".gitconfig", ".gitignore", ".gitattributes", ".sshrc",
        ".editorconfig", ".env", "dockerfile", "makefile", "gemfile",
        "rakefile", "procfile", "license", "readme", "changelog"
    ]

    private func subtitle(for file: RemoteFile) -> String {
        var parts: [String] = []
        if !file.isDirectory, let size = file.size {
            parts.append(Int(clamping: size).formatted(.byteCount(style: .file)))
        }
        if let modified = file.modified {
            parts.append(modified.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: "  ")
    }

    @ViewBuilder
    private func menuItems(_ file: RemoteFile) -> some View {
        if !file.isDirectory {
            Button {
                startDownload(file)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        Button {
            renameText = file.name
            renaming = file
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            chmodTarget = file
        } label: {
            Label("Permissions", systemImage: "switch.2")
        }
        Divider()
        Button(role: .destructive) {
            deleting = file
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Alert bindings

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )
    }

    /// Action errors alert only when a listing is on screen — a failed
    /// load already shows its own retry state.
    private var errorAlertPresented: Binding<Bool> {
        Binding(
            get: { vm.error != nil && !vm.files.isEmpty },
            set: { if !$0 { vm.error = nil } }
        )
    }
}

/// Owner read/write/execute as three toggles; group and other bits
/// from the file are preserved untouched.
private struct PermissionsSheet: View {
    let file: RemoteFile
    let onSave: (UInt32) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var read: Bool
    @State private var write: Bool
    @State private var execute: Bool

    init(file: RemoteFile, onSave: @escaping (UInt32) -> Void) {
        self.file = file
        self.onSave = onSave
        let perm = file.permissions ?? 0o644
        _read = State(initialValue: perm & 0o400 != 0)
        _write = State(initialValue: perm & 0o200 != 0)
        _execute = State(initialValue: perm & 0o100 != 0)
    }

    private var result: UInt32 {
        var bits = (file.permissions ?? 0o644) & ~UInt32(0o700)
        if read { bits |= 0o400 }
        if write { bits |= 0o200 }
        if execute { bits |= 0o100 }
        return bits
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                VStack(spacing: 0) {
                    toggle("Read", symbol: "eye", isOn: $read)
                    Divider().padding(.leading, 52)
                    toggle("Write", symbol: "pencil", isOn: $write)
                    Divider().padding(.leading, 52)
                    toggle("Execute", symbol: "terminal", isOn: $execute)
                }
                .padding(.vertical, 6)
                .terminalGlass(cornerRadius: 18)

                Spacer()
            }
            .padding(20)
            .background(Color.terminalSurface.ignoresSafeArea())
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Haptics.tap()
                        onSave(result)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(330)])
    }

    private func toggle(_ title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: symbol)
        }
        .tint(Color.terminalAccent)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
