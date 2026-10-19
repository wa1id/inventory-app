import Foundation
import GRDB
import InventoryCore
import InventoryNetwork
import InventoryStorage
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryServices

// Parity with src/services/household/shadow.ts, which the RN build ran on every household write.
//
// `Fixtures/household/shadow-parity.json` is a script of household writes that the generator
// (`Fixtures/household/generator/shadow-parity.test.ts`) ran through the real `withLocalShadow`
// over node:sqlite and the app's migrations, with a remote answering each write with a scripted
// server reply, a seeded clock and counted tag ids. It recorded each step's outcome, whether the
// mirror logged `household_shadow_failed`, and dumps of every local table. This suite replays the
// script through `ShadowingRepositories` over a stub home server answering the same replies,
// with the same clock and ids, and compares the tables row for row and value for value.

@Suite("withLocalShadow parity with shadow.ts")
struct ShadowParityTests {
    private static let tables = ["spaces", "containers", "items", "item_photos", "tags", "item_tags", "qr_bindings", "sync_deletions"]

    @Test("replays the shadow script and leaves exactly the rows shadow.ts left")
    func replaysTheScript() async throws {
        let fixture = try #require(JSONValue.parse(try HouseholdServicesFixtures.data("shadow-parity.json"))?.objectValue)
        let seeds = try #require(fixture["seeds"]?.objectValue)
        let clockStart = try #require(seeds["clockStart"]?.numberValue.flatMap { Int64(exactly: $0) })
        let clockStep = try #require(seeds["clockStep"]?.numberValue.flatMap { Int64(exactly: $0) })
        let idPrefix = try #require(seeds["idPrefix"]?.stringValue)
        let steps = try #require(fixture["steps"]?.arrayValue)

        let pending = Mutex<StubReply?>(nil)
        let server = StubServer { _ in pending.withLock { reply in
            defer { reply = nil }
            return reply ?? .json(599, #"{"error":"unscripted"}"#)
        } }
        let local = try householdFreshLocal()
        let clock = Mutex(clockStart)
        let ids = Mutex(0)
        let telemetry = RecordingTelemetry()
        let directory = try TemporaryDirectory()
        let remote = HTTPRepositories(
            session: householdTestSession,
            client: server.householdClient(),
            photos: HouseholdFakePhotos(),
            photoCache: HouseholdPhotoCache(resolver: PhotoPathResolver(documents: directory.documents, caches: directory.caches))
        )
        let repos = ShadowingRepositories(
            remote: remote,
            local: local,
            telemetry: TelemetryReporter(sink: telemetry),
            now: { clock.withLock { $0 += clockStep; return $0 } },
            makeId: { idPrefix + String(ids.withLock { $0 += 1; return $0 }) }
        )

        var dumps = 0
        for (index, value) in steps.enumerated() {
            let step = try #require(value.objectValue)
            let op = try #require(step["op"]?.stringValue)
            switch op {
            case "sql":
                let sql = try #require(step["sql"]?.stringValue)
                try await local.store.queue.write { db in try db.execute(sql: sql) }
            case "dump":
                dumps += 1
                let expected = try #require(step["tables"]?.objectValue)
                for table in Self.tables {
                    try compare(table: table, expected: expected[table]?.arrayValue ?? [], store: local.store, at: "step \(index) (dump \(dumps))")
                }
            default:
                pending.withLock { $0 = Self.reply(op: op, step: step) }
                telemetry.reset()
                var outcome = "ok"
                do {
                    try await Self.run(op: op, step: step, on: repos)
                } catch {
                    outcome = "error"
                }
                #expect(outcome == step["outcome"]?.stringValue, "step \(index) \(op)")
                let failed = telemetry.events.contains { $0.name == "household_shadow_failed" }
                #expect(failed == step["shadowFailed"]?.boolValue, "step \(index) \(op)")
                #expect(telemetry.errors.isEmpty, "step \(index) \(op)")
            }
        }
        #expect(dumps == 5)
        #expect(server.requests.count == steps.filter { !["sql", "dump"].contains($0.objectValue?["op"]?.stringValue ?? "") }.count)
    }

    /// The home server's answer to the step's write.
    private static func reply(op: String, step: [String: JSONValue]) -> StubReply {
        if step["remoteFails"]?.boolValue == true { return .json(500, #"{"error":"boom"}"#) }
        let reply = step["reply"] ?? .null
        let notFound = StubReply.json(404, #"{"error":"not_found"}"#)
        switch op {
        case "spaces.create", "containers.create", "items.create", "qr.createAndBind":
            return .json(201, reply.jsonText)
        case "spaces.update", "containers.update", "items.update":
            return reply == .null ? notFound : .json(200, reply.jsonText)
        case "spaces.delete", "containers.delete", "items.delete":
            return reply.objectValue?["deleted"]?.boolValue == true ? .json(200, reply.jsonText) : notFound
        case "qr.bind":
            return .json(200, reply.jsonText)
        case "qr.unbind":
            return reply.boolValue == true ? .status(204) : notFound
        default:
            return .json(599, #"{"error":"unknown op"}"#)
        }
    }

    /// Calls the decorator the way the generator called `withLocalShadow`.
    private static func run(op: String, step: [String: JSONValue], on repos: ShadowingRepositories) async throws {
        let input = step["input"]?.objectValue ?? [:]
        let id = step["id"]?.stringValue ?? ""
        let containerId = step["containerId"]?.stringValue ?? ""
        func string(_ key: String) -> String? { input[key]?.stringValue }
        func int(_ key: String) -> Int? { input[key]?.numberValue.flatMap { Int(exactly: $0) } }
        func field(_ key: String) -> FieldUpdate<String> {
            guard let value = input[key] else { return .unchanged }
            return value.stringValue.map(FieldUpdate.set) ?? .clear
        }
        switch op {
        case "spaces.create":
            _ = try await repos.spaces.create(CreateSpaceInput(name: string("name") ?? "", icon: string("icon") ?? "", color: string("color") ?? ""))
        case "spaces.update":
            _ = try await repos.spaces.update(id, UpdateSpaceInput(name: string("name"), icon: string("icon"), color: string("color")))
        case "spaces.delete":
            _ = try await repos.spaces.delete(id)
        case "containers.create":
            _ = try await repos.containers.create(CreateContainerInput(
                spaceId: string("spaceId") ?? "", name: string("name"), visualType: ContainerVisualType(rawValue: string("visualType") ?? "")
            ))
        case "containers.update":
            _ = try await repos.containers.update(id, UpdateContainerInput(
                name: field("name"), visualType: string("visualType").map(ContainerVisualType.init(rawValue:)), spaceId: string("spaceId")
            ))
        case "containers.delete":
            _ = try await repos.containers.delete(id)
        case "items.create":
            _ = try await repos.items.create(ItemDraft(containerId: string("containerId") ?? "", name: string("name")))
        case "items.update":
            _ = try await repos.items.update(id, UpdateItemInput(
                containerId: string("containerId"), name: string("name"), quantity: int("quantity"),
                expectedUpdatedAt: input["expectedUpdatedAt"]?.numberValue.flatMap { Int64(exactly: $0) }
            ))
        case "items.delete":
            _ = try await repos.items.delete(id)
        case "qr.bind":
            _ = try await repos.qr.bind(token: step["token"]?.stringValue ?? "", containerId: containerId)
        case "qr.createAndBind":
            _ = try await repos.qr.createAndBind(containerId)
        case "qr.unbind":
            _ = try await repos.qr.unbind(containerId)
        default:
            Issue.record("unknown op \(op)")
        }
    }
}

/// Compares a table, in rowid order, with what node:sqlite returned for it.
private func compare(table: String, expected: [JSONValue], store: DatabaseStore, at location: String) throws {
    let actual = try store.queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid") }
    #expect(actual.count == expected.count, "\(location): \(table) has \(actual.count) rows, expected \(expected.count)")
    for (row, expectedRow) in zip(actual, expected) {
        let members = expectedRow.objectValue ?? [:]
        #expect(Set(row.columnNames) == Set(members.keys), "\(location): \(table) columns")
        for column in row.columnNames {
            let value: DatabaseValue = row[column]
            let matches = householdSQLValue(value, equals: members[column] ?? .null)
            #expect(matches, "\(location): \(table).\(column) is \(value), expected \(members[column] ?? .null)")
        }
    }
}

/// A SQLite value against the JSON node:sqlite wrote for it: numbers by value, strings by code point.
private func householdSQLValue(_ value: DatabaseValue, equals json: JSONValue) -> Bool {
    switch (value.storage, json) {
    case (.null, .null): true
    case (.int64(let int), .number(let number)): Double(int) == number
    case (.double(let double), .number(let number)): double == number
    case (.string(let string), .string(let text)): string.unicodeScalars.elementsEqual(text.unicodeScalars)
    default: false
    }
}
