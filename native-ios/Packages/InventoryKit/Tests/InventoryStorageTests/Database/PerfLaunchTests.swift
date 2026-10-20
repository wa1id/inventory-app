import Foundation
import GRDB
import InventoryCore
import Synchronization
import Testing
@testable import InventoryStorage

/// Launch with 10 000 items (docs/PERFORMANCE.md, 02 §8): opening the database the Expo build
/// left at version 7 runs no migration and reads no rows, so launch costs the same at 10 items
/// and at 10 000. The one O(n) step, the v7 rebuild of an older phone's `items`, runs once.
@Suite("perf: launch does no per-item work")
struct PerfLaunchTests {
    @Test("reopening a 10 000-item database at version 7 runs only the version check")
    func reopenRunsNoMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "perf-launch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: DatabaseStore.fileName).path

        do {
            let first = try DatabaseStore(path: path)
            try first.migrate()
            _ = try first.queue.write { db in
                try PerfInventorySeed.write(.large, now: 1_790_000_000_000, in: db)
            }
            try first.close()
        }

        // The second launch: open the file in place and migrate, as `DatabaseStore.openLive` does.
        let store = try DatabaseStore(path: path)
        let statements = PerfLaunchStatements()
        store.queue.inDatabase { db in
            db.trace { event in statements.append("\(event)") }
        }
        let version = try store.migrate()
        store.queue.inDatabase { db in db.trace(nil) }

        #expect(version == Migration.latestSchemaVersion)
        let ran = statements.all
        #expect(!ran.isEmpty)
        // Pragmas only: no table is read, written, created or rebuilt.
        #expect(ran.allSatisfy { $0.uppercased().hasPrefix("PRAGMA") }, "\(ran)")
        #expect(try store.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items") } == 10_000)
    }
}

/// Statements a trace saw, oldest first.
private final class PerfLaunchStatements: Sendable {
    private let state = Mutex<[String]>([])

    var all: [String] { state.withLock { $0 } }

    func append(_ statement: String) {
        state.withLock { $0.append(statement) }
    }
}
