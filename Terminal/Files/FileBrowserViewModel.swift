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
    /// Which warm-cache key `sftp` was leased under — needed to disarm
    /// its idle eviction when the view reappears.
    private var serviceKey: ObjectIdentifier?
    private var serviceInFlight: Task<(SFTPService, ObjectIdentifier), Error>?
    private var home: String?
    /// Bumped on every navigation/load so a stale response can never
    /// overwrite a newer folder's listing.
    private var generation = 0

    /// SFTP channels kept warm so transfers keep running after the
    /// browser is dismissed and re-opening is instant.
    ///
    /// Keyed by the SSHConnection's OBJECT IDENTITY, not the profile:
    /// a pooled reconnect produces a new connection object, so a stale
    /// channel bound to a dead transport can never be handed out after
    /// `invalidateConnection` swaps the pool entry.
    private final class WarmRef {
        let service: SFTPService
        var idleTask: Task<Void, Never>?
        init(service: SFTPService) { self.service = service }
    }
    private static var warm: [ObjectIdentifier: WarmRef] = [:]
    /// profile → cache keys in use — lets `evictWarm(profileID:)` find
    /// entries without knowing the connection objects.
    private static var warmKeysByProfile: [UUID: Set<ObjectIdentifier>] = [:]
    /// How long a service with no live users stays warm before close.
    private static let warmIdle: Duration = .seconds(120)

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
    /// Concurrent callers share one in-flight open task — no duplicate
    /// channels from parallel callers. The channel is keyed to the
    /// connection OBJECT: a reconnected transport always yields a new
    /// object identity and therefore a fresh channel.
    func service() async throws -> SFTPService {
        if let sftp {
            if sftp.isChannelAlive { return sftp }
            // Our own channel died — invalidate before reopening so the
            // lease books stay balanced.
            evict()
        }
        if let task = serviceInFlight { return try await task.value.0 }
        let task = Task<(SFTPService, ObjectIdentifier), Error> { [profile, engine] in
            let connection = engine.connection(for: profile)
            let key = ObjectIdentifier(connection)
            if let cached = Self.warm[key] {
                if cached.service.isChannelAlive {
                    // Still ours and still alive — disarm idle eviction.
                    cached.idleTask?.cancel()
                    cached.idleTask = nil
                    return (cached.service, key)
                }
                // Channel died underneath: never hand out a corpse.
                cached.idleTask?.cancel()
                Self.warm[key] = nil
                Self.warmKeysByProfile[profile.id]?.remove(key)
                cached.service.invalidate()
            }
            let fresh = SFTPService(sftp: try await connection.openSFTP())
            let ref = WarmRef(service: fresh)
            Self.warm[key] = ref
            Self.warmKeysByProfile[profile.id, default: []].insert(key)
            Self.armIdleEviction(key: key, ref: ref, profileID: profile.id)
            return (fresh, key)
        }
        serviceInFlight = task
        defer { serviceInFlight = nil }
        let (svc, key) = try await task.value
        if sftp !== svc {
            sftp?.removeLease()
            svc.addLease()
            sftp = svc
            serviceKey = key
        }
        return svc
    }

    /// stat() through the channel — resolves what a symlink actually is.
    func resolve(_ file: RemoteFile) async -> RemoteFile? {
        guard file.isSymlink else { return file }
        do {
            let attrs = try await service().stat(path: file.path)
            let perms = attrs.permissions ?? 0
            var resolved = file
            if perms & 0o170000 == 0o040000 {
                resolved.isDirectory = true
            }
            return resolved
        } catch {
            return file
        }
    }

    /// Drops the view's hold on the channel without closing it — it
    /// stays warm so transfers finish and reopening is instant. The
    /// idle timer is re-armed now that this view's lease is gone.
    func park() {
        sftp?.removeLease()
        if let key = serviceKey, let ref = Self.warm[key] {
            Self.armIdleEviction(key: key, ref: ref, profileID: profile.id)
        }
        sftp = nil
        serviceKey = nil
    }

    /// Called when a profile is edited or deleted — its warm channel may
    /// point at the old host, so it must not be reused. Invalidation
    /// still respects live leases: an in-flight transfer finishes on
    /// the doomed channel, then it's closed.
    static func evictWarm(profileID: UUID) {
        guard let keys = warmKeysByProfile.removeValue(forKey: profileID) else { return }
        for key in keys {
            guard let ref = warm.removeValue(forKey: key) else { continue }
            ref.idleTask?.cancel()
            ref.service.invalidate()
        }
    }

    /// Close a warm service once nobody uses it for `warmIdle`. While
    /// leases exist the check re-arms — only genuinely idle channels
    /// are torn down.
    private static func armIdleEviction(key: ObjectIdentifier, ref: WarmRef, profileID: UUID) {
        ref.idleTask?.cancel()
        ref.idleTask = Task { [service = ref.service] in
            while true {
                try? await Task.sleep(for: warmIdle)
                if Task.isCancelled { return }
                guard Self.warm[key] === ref else { return }
                if service.hasLeases { continue }
                Self.warm[key] = nil
                Self.warmKeysByProfile[profileID]?.remove(key)
                service.invalidate()
                return
            }
        }
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
        generation += 1
        let gen = generation
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await attemptList()
            guard gen == generation else { return }
            files = list
            error = nil
        } catch {
            // Channel may be stale — drop it and retry once on a fresh one.
            evict()
            do {
                let list = try await attemptList()
                guard gen == generation else { return }
                files = list
                self.error = nil
                return
            } catch {}
            // Folder may be gone — fall back to home before giving up.
            if let home, home != path {
                do {
                    let list = try await attemptList()
                    guard gen == generation else { return }
                    path = home
                    files = list
                    self.error = nil
                    return
                } catch {}
            }
            guard gen == generation else { return }
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
        generation += 1
        let gen = generation
        isLoading = true
        defer { isLoading = false }
        do {
            let svc = try await service()
            let list = sort(try await svc.list(path: newPath))
            commit(gen, newPath, list)
        } catch {
            evict()
            do {
                let svc = try await service()
                let list = sort(try await svc.list(path: newPath))
                commit(gen, newPath, list)
            } catch {
                guard gen == generation else { return }
                fail("Couldn't open folder")
            }
        }
    }

    private func commit(_ gen: Int, _ newPath: String, _ list: [RemoteFile]) {
        guard gen == generation else { return }
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

    /// Drop a suspect channel: remove it from the warm cache (so it can
    /// never be handed out again) and invalidate it. Invalidation closes
    /// immediately only when nothing holds a lease — a live transfer on
    /// the channel keeps it until it drains, then it's closed. The next
    /// service() call opens a fresh channel on the pooled transport.
    private func evict() {
        guard let sftp else { return }
        if let key = serviceKey, let ref = Self.warm[key], ref.service === sftp {
            ref.idleTask?.cancel()
            Self.warm[key] = nil
            Self.warmKeysByProfile[profile.id]?.remove(key)
        }
        sftp.removeLease()
        sftp.invalidate()
        self.sftp = nil
        serviceKey = nil
    }
}
