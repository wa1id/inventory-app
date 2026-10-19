import Foundation
import GRDB
import InventoryCore
import InventoryTestSupport
import Testing
@testable import InventoryStorage

/// Databases at every historical `user_version`, written by the real TypeScript migrations
/// stopped at that version (Fixtures/db/historical), opened with `DatabaseStore` and migrated
/// (01 §13.8 #4, 02 §11.2 #8).
@Suite("historical databases")
struct HistoricalFixtureTests {
    struct Fixture: Decodable, CustomTestStringConvertible {
        let version: Int
        let file: String
        let countsBefore: [String: Int]
        let schemaBefore: [MasterRow]
        let expectedAfter: [String: [ScalarRow]]

        var testDescription: String { "user_version \(version)" }
    }

    struct Fixtures: Decodable {
        let fixtures: [Fixture]
    }

    static let fixtures: [Fixture] = {
        (try? DatabaseFixtures.decode(Fixtures.self, from: "historical.json").fixtures) ?? []
    }()

    @Test("there is a fixture for every version below the latest")
    func coversEveryVersion() {
        #expect(Self.fixtures.map(\.version) == Array(0..<Migration.latestSchemaVersion))
    }

    @Test("each fixture is at its version before opening", arguments: fixtures)
    func fixtureIsAtItsVersion(_ fixture: Fixture) throws {
        let scratch = try TemporaryDirectory()
        let path = try DatabaseFixtures.copy("historical/\(fixture.file)", into: scratch)
        let queue = try DatabaseQueue(path: path)
        let (version, schema) = try queue.read { db in (try MigrationRunner.userVersion(db), try sqliteMaster(db)) }
        #expect(version == fixture.version)
        #expect(schema == fixture.schemaBefore)
    }

    @Test("migrates to 7 without losing a row, exactly as the TypeScript runner does", arguments: fixtures)
    func migratesWithoutLoss(_ fixture: Fixture) throws {
        let scratch = try TemporaryDirectory()
        let path = try DatabaseFixtures.copy("historical/\(fixture.file)", into: scratch)
        let store = try DatabaseStore(path: path)

        #expect(try store.migrate() == Migration.latestSchemaVersion)

        try store.queue.read { db in
            #expect(try userTables(db).sorted() == fixture.expectedAfter.keys.sorted())
            for (table, expectedRows) in fixture.expectedAfter {
                let rows = try dumpTable(db, table)
                #expect(rows.count == expectedRows.count, "\(table) row count")
                if let before = fixture.countsBefore[table] {
                    #expect(rows.count >= before, "\(table) lost rows")
                }
                for (actual, expected) in zip(rows, expectedRows) {
                    #expect(
                        Self.comparable(actual, table: table, fixture: fixture)
                            == Self.comparable(expected, table: table, fixture: fixture),
                        "\(table) row differs"
                    )
                }
            }
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            #expect(try sqliteMaster(db) == SqliteMasterFixture.load().rows)
        }
        #expect(try pragma(store, "foreign_keys") == "1")
    }

    /// The drop-zone rows a pre-v3 file gets are stamped with the time migration 3 ran.
    private static func comparable(_ row: ScalarRow, table: String, fixture: Fixture) -> ScalarRow {
        guard fixture.version < 3, table == "spaces" || table == "containers",
              case .string(let id) = row["id"], id == DropZone.spaceId || id == DropZone.containerId
        else { return row }
        var stable = row
        stable["created_at"] = nil
        stable["updated_at"] = nil
        return stable
    }

    @Test("keeps the photo and tag rows of a v6 phone through the v7 items rebuild")
    func v6RebuildKeepsPhotosAndTags() async throws {
        let scratch = try TemporaryDirectory()
        let path = try DatabaseFixtures.copy("historical/v6.db", into: scratch)
        let store = try DatabaseStore(path: path)
        #expect(try await store.schemaVersion() == 6)
        let photosBefore = try count(store, "item_photos")
        let tagLinksBefore = try count(store, "item_tags")
        try #require(photosBefore > 0 && tagLinksBefore > 0)

        try await store.migrate()

        #expect(try count(store, "item_photos") == photosBefore)
        #expect(try count(store, "item_tags") == tagLinksBefore)
        #expect(try pragma(store, "foreign_keys") == "1")
        #expect(try store.queue.read { db in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check") }.isEmpty)

        let drill = try #require(try await repositories(store).items.getById("it-drill"))
        #expect(drill.photoId == "ph-drill")
        // Tag order follows the item_tags primary key: tag id order (tg-18v, tg-dewalt).
        #expect(drill.tags == ["18V", "DeWalt"])
        // Quantity 0 is allowed now, and the old rows are still writable.
        let emptied = try await repositories(store).items.update("it-drill", UpdateItemInput(quantity: 0))
        #expect(emptied?.quantity == 0)
    }

    @Test("a missing file starts empty and migrates like a fresh install")
    func missingFileIsFreshInstall() throws {
        let scratch = try TemporaryDirectory()
        let store = try DatabaseStore(path: scratch.path("inventory.db"))
        #expect(try store.schemaVersion() == 0)
        #expect(try store.migrate() == 7)
        #expect(try count(store, "spaces") == 1)
        #expect(try count(store, "containers") == 1)
    }
}
