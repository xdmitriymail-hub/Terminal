import Foundation
import SwiftUI

/// Owns one remote folder per profile: lazy SFTP channel, breadcrumbs,
/// sorting, search and every file mutation. All state is MainActor.
@MainActor
final class FileBrowserViewModel: ObservableObject {
    /// One breadcrumb pill; `name` is "/" only for the root crumb.
    struct Crumb: Identifiable, Hashable {
        var id: String { path }
        let name: String
        let path: String
    }

    let profile: ServerProfile

    @Published private(set) var files: [RemoteFile] = []
    @Published private(set) var path = ""
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published var searchText = ""

    private let engine: SessionEngine
    private var sftp: SFTPService?
    private var home: String?

    /// SFTP channels kept warm per profile so transfers keep running
    /// after the browser is dismissed and re-opening is instant.
    private static var warmServices: [UUID: SFTPService] = [:]

    init(profile: ServerProfile, engine: SessionEngine) {
        self.profile = profile
        self.engine = engine
    }

    // MARK: - Derived state

    var breadcrumbs: [Crumb] {
        var crumbs = [Crumb(name: "/", path: "/")]
        var current = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + part
            crumbs.append(Crumb(name: String(part), path: current))
        }
        return crumbs
    }

    var canGoUp: Bool {
        !path.isEmpty && path != "/"
    }

    /// Folders first, then name — filtered by the search field.
    var visibleFiles: [RemoteFile] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Remote path for a name inside the current folder.
    func remotePath(for name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }

    // MARK: - Connection

    /// Lazily opens (or reuses) the SFTP channel for this profile.
    func service() async throws -> SFTPService {
        if let sftp { return sftp }
        if let warm = Self.warmServices[profile.id] {
            sftp = warm
            return warm
        }
        let connection = engine.connection(for: profile)
        let fresh = SFTPService(sftp: try await connection.openSFTP())
        Self.warmServices[profile.id] = fresh
        sftp = fresh
        return fresh
    }

    /// Drops the view's hold on the channel without closing it — it
    /// stays warm so transfers finish and reopening is instant.
    func park() {
        sftp = nil
    }

    /// Called when a profile is edited or deleted — its warm channel may
    /// point at the old host, so it must not be reused.
    static func evictWarm(profileID: UUID) {
        guard let service = warmServices.removeValue(forKey: profileID) else { return }
        Task { await service.close() }
    }

    // MARK: - Loading

    /// First open: connect, resolve home, list. Later calls just reload.
    func open() async {
        if sftp == nil {
            isLoading = true
            error = nil
            do {
                let svc = try await service()
                if home == nil { home = try? await svc.homePath }
                if path.isEmpty { path = home ?? "/" }
            } catch {
                isLoading = false
                fail("Couldn't connect")
                return
            }
        }
        await load()
    }

    func reload() async {
        await load()
    }

    func retry() async {
        error = nil
        await open()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            files = try await attemptList()
            error = nil
        } catch {
            // Channel may be stale — drop it and retry once on a fresh one.
            evict()
            do {
                files = try await attemptList()
                self.error = nil
                return
            } catch {}
            // Folder may be gone — fall back to home before giving up.
            if let home, home != path {
                path = home
                do {
                    files = try await attemptList()
                    self.error = nil
                    return
                } catch {}
            }
            fail("Couldn't load folder")
        }
    }

    private func attemptList() async throws -> [RemoteFile] {
        let svc = try await service()
        return sort(try await svc.list(path: path))
    }

    // MARK: - Navigation

    func navigate(_ file: RemoteFile) async {
        guard file.isDirectory else { return }
        await go(to: file.path)
    }

    /// Breadcrumb jump.
    func jump(to newPath: String) async {
        guard !newPath.isEmpty, newPath != path else { return }
        await go(to: newPath)
    }

    func up() async {
        guard canGoUp else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await go(to: parent.isEmpty ? "/" : parent)
    }

    /// Path only commits after the listing succeeds — a failed jump
    /// never strands the view in a folder it can't show.
    private func go(to newPath: String) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let svc = try await service()
            let list = sort(try await svc.list(path: newPath))
            commit(newPath, list)
        } catch {
            evict()
            do {
                let svc = try await service()
                let list = sort(try await svc.list(path: newPath))
                commit(newPath, list)
            } catch {
                fail("Couldn't open folder")
            }
        }
    }

    private func commit(_ newPath: String, _ list: [RemoteFile]) {
        withAnimation(.easeInOut(duration: 0.2)) {
            path = newPath
            files = list
        }
        error = nil
        searchText = ""
    }

    // MARK: - Mutations

    func makeDir(name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let sftp, isValidName(name) else { return }
        do {
            try await sftp.mkdir(path: remotePath(for: name))
            Haptics.tap()
            await load()
        } catch {
            fail("Couldn't create folder")
        }
    }

    func delete(file: RemoteFile) async {
        guard let sftp else { return }
        do {
            try await sftp.delete(file: file)
            withAnimation(.easeInOut(duration: 0.2)) {
                files.removeAll { $0.id == file.id }
            }
            Haptics.tap()
        } catch {
            fail("Couldn't delete")
        }
    }

    func rename(file: RemoteFile, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let sftp, isValidName(name), name != file.name else { return }
        let directory = (file.path as NSString).deletingLastPathComponent
        let destination = (directory as NSString).appendingPathComponent(name)
        do {
            try await sftp.rename(from: file.path, to: destination)
            Haptics.tap()
            await load()
        } catch {
            fail("Couldn't rename")
        }
    }

    func chmod(file: RemoteFile, perm: UInt32) async {
        guard let sftp else { return }
        do {
            try await sftp.chmod(path: file.path, permissions: perm)
            Haptics.tap()
            await load()
        } catch {
            fail("Couldn't change permissions")
        }
    }

    // MARK: - Private

    private func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private func sort(_ list: [RemoteFile]) -> [RemoteFile] {
        list.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func fail(_ message: String) {
        error = message
        Haptics.failed()
    }

    /// Drop a suspect channel: forget it everywhere and close it, so the
    /// next service() call opens a fresh one on the pooled transport.
    private func evict() {
        guard let sftp else { return }
        if Self.warmServices[profile.id] === sftp {
            Self.warmServices[profile.id] = nil
        }
        self.sftp = nil
        Task { await sftp.close() }
    }
}
