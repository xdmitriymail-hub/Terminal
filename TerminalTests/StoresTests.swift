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
        let store = JSONStore<[String]>("t", initial: [], version: 2, directory: dir) { _, value in
            value.append("migrated")
        }
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
}
