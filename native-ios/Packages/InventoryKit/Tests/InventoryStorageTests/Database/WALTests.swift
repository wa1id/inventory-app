import Foundation
import GRDB
import InventoryCore
import InventoryTestSupport
import Testing
@testable import InventoryStorage

/// Rows committed only to the -wal file survive opening the database in place
/// (01 §2.1, §13.8 #9; 02 §2.3 rule 1, §11.2 #7).
@Suite("write-ahead log")
struct WALTests {
    struct Fixture: Decodable {
        struct Updated: Decodable {
            let id: String
            let quantity: Int
            let updated_at: Int64
        }
        let userVersion: Int
        let walOnly: [String: [String]]
        let updatedInWal: Updated
        let expectedAfter: [String: [ScalarRow]]
    }

    @Test("a v4 file written by node:sqlite keeps its WAL-only rows when opened and migrated", arguments: [
        ["-wal", "-shm"], ["-wal"],
    ])
    func walOnlyRowsSurvive(sidecars: [String]) throws {
        let fixture = try DatabaseFixtures.decode(Fixture.self, from: "wal.json")
        let scratch = try TemporaryDirectory()
        let path = try DatabaseFixtures.copy("wal/v4.db", sidecars: sidecars, into: scratch)

        let store = try DatabaseStore(path: path)
        #expect(try store.schemaVersion() == fixture.userVersion)
        #expect(try store.migrate() == 7)

        try store.queue.read { db in
            for (table, ids) in fixture.walOnly {
                for id in ids {
                    let found = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE id = ?", arguments: [id])
                    #expect(found == 1, "\(table) \(id) was lost")
                }
            }
            let nails = try Row.fetchOne(db, sql: "SELECT quantity, updated_at FROM items WHERE id = ?", arguments: [fixture.updatedInWal.id])
            #expect(nails?["quantity"] as Int? == fixture.updatedInWal.quantity)
            #expect(nails?["updated_at"] as Int64? == fixture.updatedInWal.updated_at)

            for (table, expected) in fixture.expectedAfter {
                #expect(try dumpTable(db, table) == expected, "\(table) differs from the TypeScript result")
            }
        }
    }

    @Test("the fixture's main file alone does not have those rows")
    func mainFileAloneLacksRows() throws {
        let scratch = try TemporaryDirectory()
        let path = try DatabaseFixtures.copy("wal/v4.db", into: scratch)
        let queue = try DatabaseQueue(path: path)
        let found = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE id = 'it-wal'") }
        #expect(found == 0)
    }

    @Test("rows a GRDB writer left uncheckpointed survive a copy-and-reopen, as after a crash")
    func grdbWalRowsSurvive() async throws {
        let live = try TemporaryDirectory()
        let crashed = try TemporaryDirectory()
        let livePath = live.path("inventory.db")

        let writer = try DatabaseStore(path: livePath)
        try await writer.migrate()
        try await writer.queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let repos = repositories(writer)
        let (space, container) = try await seedSpaceAndContainer(repos)
        _ = try await repos.items.create(ItemDraft(containerId: container.id, name: "Only in the WAL"))

        // The process "dies": copy the files while the writer still holds them.
        let walSize = try FileManager.default.attributesOfItem(atPath: livePath + "-wal")[.size] as? Int ?? 0
        #expect(walSize > 0)
        for suffix in ["", "-wal", "-shm"] {
            try FileManager.default.copyItem(atPath: livePath + suffix, toPath: crashed.path("inventory.db") + suffix)
        }

        let reopened = try DatabaseStore(path: crashed.path("inventory.db"))
        #expect(try await reopened.migrate() == 7)
        let names = try await repositories(reopened).items.listByContainer(container.id).map(\.name)
        #expect(names == ["Only in the WAL"])
        #expect(try await repositories(reopened).spaces.getById(space.id)?.name == "Garage")
        try writer.close()
    }
}
