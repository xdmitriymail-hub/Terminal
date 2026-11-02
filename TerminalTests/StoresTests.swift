import XCTest
@testable import Terminal

/// JSONStore lifecycle: fresh install, restart, corruption, schema guard.
final class StoresTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stores-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore(name: String = "t") -> JSONStore<[String]> {
        JSONStore(name, initial: [], directory: dir)
    }

    func testFreshInstallIsWritableAndEmpty() {
        let store = makeStore()
        XCTAssertEqual(store.load(), [])
        XCTAssertTrue(store.writable)
        XCTAssertTrue(store.save(["a"]))
    }

    func testFirstSaveCreatesFile() {
        let store = makeStore()
        XCTAssertTrue(store.save(["x", "y"]))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("t.json").path
        ))
    }

    func testRoundtripAcrossInstances() {
        XCTAssertTrue(makeStore().save(["persisted"]))
        XCTAssertEqual(makeStore().load(), ["persisted"])
    }

    func testCorruptFileBlocksWritesAndKeepsData() {
        let store = makeStore()
        XCTAssertTrue(store.save(["real-data"]))
        let fileURL = dir.appendingPathComponent("t.json")
        try! Data("garbage{not-json".utf8).write(to: fileURL)

        // A fresh instance hits the corrupt file: initial value, blocked.
        let reopened = makeStore()
        XCTAssertEqual(reopened.load(), [])
        XCTAssertFalse(reopened.writable)
        // save() must refuse — the corrupt file still holds user data.
        XCTAssertFalse(reopened.save(["clobber"]))
        XCTAssertEqual(try! Data(contentsOf: fileURL), Data("garbage{not-json".utf8))
    }

    func testMissingFileAfterCorruptionRecoverableOnNextLaunch() {
        // Simulates the OS deleting the file between runs: the next store
        // treats it as a fresh install (missing ≠ corrupt).
        let store = makeStore()
        XCTAssertTrue(store.save(["a"]))
        try! FileManager.default.removeItem(at: dir.appendingPathComponent("t.json"))
        let reopened = makeStore()
        XCTAssertEqual(reopened.load(), [])
        XCTAssertTrue(reopened.writable)
    }

    func testNewerSchemaIsNotClobbered() {
        // Write a box whose version is ahead of this build's — the store
        // must surface the payload but refuse to overwrite the file.
        struct Box: Codable { var version: Int; var payload: [String] }
        let ahead = Box(version: 99, payload: ["newer"])
        try! JSONEncoder().encode(ahead).write(to: dir.appendingPathComponent("t.json"))

        let store = makeStore()
        XCTAssertEqual(store.load(), ["newer"])
        XCTAssertFalse(store.writable)
        XCTAssertFalse(store.save(["old-app-data"]))
    }

    func testMigrationRunsForOlderSchema() {
        struct Box: Codable { var version: Int; var payload: [String] }
        try! JSONEncoder().encode(Box(version: 1, payload: ["v1"])).write(
            to: dir.appendingPathComponent("t.json"))
        let store = JSONStore<[String]>("t", initial: [], version: 2, directory: dir, migrate: { _, value in
            value.append("migrated")
        })
        XCTAssertEqual(store.load(), ["v1", "migrated"])
    }

    func testLegacyUnversionedFileStillLoads() {
        try! JSONEncoder().encode(["legacy"]).write(to: dir.appendingPathComponent("t.json"))
        let store = makeStore()
        XCTAssertEqual(store.load(), ["legacy"])
        // And becomes versioned on the next save.
        XCTAssertTrue(store.save(["legacy", "v2"]))
        XCTAssertEqual(makeStore().load(), ["legacy", "v2"])
    }

    // MARK: - Locked → unlock recovery (#29)

    /// A permission-denied file stands in for pre-unlock data
    /// protection: the store must report `.locked`, stay writable only
    /// via an explicit retry, and recover once readable again.
    func testLockedStoreRetriesOnlyViaUnlockHook() throws {
        XCTAssertTrue(makeStore().save(["secret"]))
        let fileURL = dir.appendingPathComponent("t.json")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        }

        let locked = makeStore()
        XCTAssertEqual(locked.load(), [])
        XCTAssertEqual(locked.state, .locked)
        XCTAssertFalse(locked.writable)

        // Still unreadable: the retry hook refuses to recover.
        XCTAssertFalse(locked.retryAfterUnlock())
        XCTAssertEqual(locked.state, .locked)

        // Permissions restored (device unlocked): the hook recovers.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        XCTAssertTrue(locked.retryAfterUnlock())
        XCTAssertEqual(locked.load(), ["secret"])
        XCTAssertTrue(locked.writable)
    }

    /// The unlock hook must NOT touch corrupt state — recovery there
    /// is a user decision, and the raw bytes stay rescuable meanwhile.
    func testCorruptStoreIsNotRetriedAndStaysExportable() throws {
        try Data("junk{".utf8).write(to: dir.appendingPathComponent("t.json"))
        let store = makeStore()
        XCTAssertEqual(store.load(), [])
        XCTAssertEqual(store.state, .corrupt)
        XCTAssertFalse(store.retryAfterUnlock())
        XCTAssertEqual(store.state, .corrupt)
        XCTAssertEqual(store.unrecoverableFileContents(), Data("junk{".utf8))
    }

    // MARK: - Save only publishes on success (#5/#29)

    /// A failed write must not leak into the cached value — load()
    /// keeps returning what is actually on disk.
    func testFailedSaveDoesNotPublishCache() throws {
        let store = makeStore()
        XCTAssertTrue(store.save(["on-disk"]))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }
        XCTAssertFalse(store.save(["unsaved"]))
        XCTAssertEqual(store.load(), ["on-disk"])
        XCTAssertNotNil(store.lastError)
        // And once writable again, a retry really does persist.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertTrue(store.save(["unsaved"]))
        XCTAssertEqual(makeStore().load(), ["unsaved"])
    }

    /// A blocked store must refuse saves outright — previously a
    /// blocked save still poisoned the cache, so load() could return
    /// data that never hit disk.
    func testBlockedStoreSaveReturnsFalseAndKeepsCache() throws {
        try Data("junk{".utf8).write(to: dir.appendingPathComponent("t.json"))
        let store = makeStore()
        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(store.save(["attempted"]))
        XCTAssertEqual(store.load(), [])
        XCTAssertEqual(try! Data(contentsOf: dir.appendingPathComponent("t.json")),
                       Data("junk{".utf8))
    }

    // MARK: - Old-schema settings decode (#29)

    /// A versioned file whose payload predates newer AppSettings fields:
    /// strict decode fails on the missing keys, the tolerant reader
    /// must fill current defaults instead of locking the file.
    @MainActor
    func testOldSchemaSettingsMissingNewFieldsDecodeWithDefaults() throws {
        let json = #"{"version":1,"payload":{"keepAlive":true,"themeID":"dark","appearance":"light"}}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("AppSettings.json"))
        let settings = SettingsStore(directory: dir)
        XCTAssertTrue(settings.settings.keepAlive)
        XCTAssertEqual(settings.settings.themeID, "dark")
        XCTAssertEqual(settings.settings.appearance, .light)
        // Absent fields take current defaults.
        XCTAssertFalse(settings.settings.remoteClipboard)
        XCTAssertEqual(settings.settings.fontSize, 13)
        XCTAssertTrue(settings.settings.autoReconnect)
        XCTAssertNil(settings.storageError)
        XCTAssertFalse(settings.storageBlocked)
    }

    /// Same for a bare unversioned settings payload.
    @MainActor
    func testBareLegacySettingsDecodeWithDefaults() throws {
        try Data(#"{"haptics":false}"#.utf8)
            .write(to: dir.appendingPathComponent("AppSettings.json"))
        let settings = SettingsStore(directory: dir)
        XCTAssertFalse(settings.settings.haptics)
        XCTAssertTrue(settings.settings.showKeyboardBar)   // default
        XCTAssertFalse(settings.storageBlocked)
    }

    /// A failed settings write must not leave the published value
    /// showing a change that never persisted — it reverts.
    @MainActor
    func testFailedSettingsWriteReverts() throws {
        let settings = SettingsStore(directory: dir)
        XCTAssertFalse(settings.settings.keepAlive)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }
        settings.settings.keepAlive = true
        XCTAssertFalse(settings.settings.keepAlive)
        XCTAssertNotNil(settings.storageError)
    }
}
