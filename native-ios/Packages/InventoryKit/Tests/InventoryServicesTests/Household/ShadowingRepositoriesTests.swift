import Foundation
import GRDB
import InventoryCore
import InventoryNetwork
import InventoryStorage
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryServices

// RN: src/services/household/__tests__/shadow.test.ts, plus the 04 §7 rules the RN suite does
// not pin. ShadowParityTests replays a longer script through the real shadow.ts.

private struct ShadowFixture {
    let server: StubServer
    let local: LocalRepositories
    let repos: ShadowingRepositories
    let telemetry = RecordingTelemetry()

    init(now: Int64 = 1_000, _ handler: @escaping StubServer.Handler) throws {
        server = StubServer(handler)
        local = try householdFreshLocal()
        let remote = HTTPRepositories(
            session: householdTestSession, client: server.householdClient(),
            photos: HouseholdFakePhotos(), photoCache: HouseholdPhotoCache(resolver: PhotoPathResolver(caches: FileManager.default.temporaryDirectory))
        )
        let ids = Mutex(0)
        repos = ShadowingRepositories(
            remote: remote, local: local, telemetry: TelemetryReporter(sink: telemetry),
            now: { now },
            makeId: { "tag-\(ids.withLock { $0 += 1; return $0 })" }
        )
    }

    var store: DatabaseStore { local.store }
    var shadowFailures: [RecordingTelemetry.Entry] { telemetry.entries.filter { $0.name == "household_shadow_failed" } }

    func exec(_ sql: String) throws {
        try store.queue.write { db in try db.execute(sql: sql) }
    }
}

private let spaceJSON = ##"{"id":"space-server","name":"Garage","icon":"🚗","color":"#5B8DEF","createdAt":1,"updatedAt":1}"##

@Suite("withLocalShadow")
struct ShadowingRepositoriesTests {
    @Test("mirrors a successful household create into local SQLite")
    func mirrorsASuccessfulHouseholdCreateIntoLocalSQLite() async throws {
        let fixture = try ShadowFixture { request in
            if request.path == "/v1/spaces", request.method == "POST" { return .json(201, spaceJSON) }
            return .json(404, "{}")
        }
        let space = try await fixture.repos.spaces.create(CreateSpaceInput(name: "Garage", icon: "🚗", color: "#5B8DEF"))
        #expect(space.id == "space-server")
        #expect(try await fixture.local.spaces.getById("space-server")?.name == "Garage")
    }
}

@Suite("ShadowingRepositories (04 §7)")
struct ShadowingRepositoriesRulesTests {
    @Test("a failed household write is not mirrored and its error reaches the caller")
    func failedWriteIsNotMirrored() async throws {
        let fixture = try ShadowFixture { _ in .json(500, #"{"error":"boom"}"#) }
        await #expect(throws: HouseholdHttpError(status: 500, code: "boom")) {
            _ = try await fixture.repos.spaces.create(CreateSpaceInput(name: "Garage", icon: "", color: ""))
        }
        #expect(try householdCount(fixture.store, "spaces", where: "kind = 'normal'") == 0)
        #expect(fixture.shadowFailures.isEmpty)
    }

    @Test("reads and search go to the household only")
    func readsPassThrough() async throws {
        let fixture = try ShadowFixture { request in
            request.path == "/v1/spaces"
                ? .json(200, #"{"spaces":[{"id":"s1","name":"Garage","icon":"","color":"","createdAt":1,"updatedAt":1,"containerCount":0,"itemCount":0}]}"#)
                : .json(200, #"{"terms":[],"locations":[],"items":[]}"#)
        }
        #expect(try await fixture.repos.spaces.listWithCounts().map(\.id) == ["s1"])
        _ = try await fixture.repos.search.search("x")
        #expect(fixture.server.requests.map(\.path) == ["/v1/spaces", "/v1/search?q=x"])
        #expect(try householdCount(fixture.store, "spaces", where: "kind = 'normal'") == 0)
    }

    @Test("a mirror that fails is logged as an event and never fails the write")
    func mirrorFailureIsAnEvent() async throws {
        // The server moved the item into a container this phone has never seen: the local
        // foreign key refuses the row.
        let fixture = try ShadowFixture { _ in
            .json(200, #"{"id":"i1","containerId":"elsewhere","name":"Drill","category":null,"quantity":1,"notes":null,"createdAt":1,"updatedAt":2}"#)
        }
        let item = try await fixture.repos.items.update("i1", UpdateItemInput(containerId: "elsewhere"))
        #expect(item?.id == "i1")
        #expect(fixture.shadowFailures == [RecordingTelemetry.Entry(level: "event", name: "household_shadow_failed", payload: ["errorClass": .string("DatabaseError")])])
        #expect(fixture.telemetry.errors.isEmpty)
    }

    @Test("an item create mirrors the space, container, item, photo and tags; tags are found by their lower-cased name")
    func itemGraph() async throws {
        let fixture = try ShadowFixture(now: 777) { _ in
            .json(201, householdItemJSON(
                id: "i1", containerId: "c1", name: " Drill ", photoId: "p1",
                photoUri: "r2:household/primary/photos/p1.webp", photoThumbUri: "r2:household/primary/photos/p1-thumb.webp",
                tags: ["  Power ", "power", "", "Café"], spaceId: "s1", containerShortCode: "BOX-7K2M"
            ))
        }
        try fixture.exec("INSERT INTO tags (id, name, normalized_name, created_at) VALUES ('t-power', 'POWER', 'power', 5)")
        let item = try await fixture.repos.items.create(ItemDraft(containerId: "c1", name: "Drill"))
        #expect(item.id == "i1")

        let space = try #require(try householdRows(fixture.store, "spaces").first { $0["id"] == "s1".databaseValue })
        #expect(space["name"] == "Garage".databaseValue)
        #expect(space["updated_at"] == 10.databaseValue)
        let container = try #require(try householdRows(fixture.store, "containers").first { $0["id"] == "c1".databaseValue })
        #expect(container["visual_type"] == "box".databaseValue)
        #expect(container["short_code"] == "BOX-7K2M".databaseValue)
        #expect(container["kind"] == "normal".databaseValue)
        let row = try #require(try householdRows(fixture.store, "items").first)
        #expect(row["search_text"] == "drill".databaseValue)
        let photo = try #require(try householdRows(fixture.store, "item_photos").first)
        #expect(photo["uri"] == "r2:household/primary/photos/p1.webp".databaseValue)
        #expect(photo["remote_synced_at"] == 777.databaseValue)
        #expect(photo["width"] == .null)
        let tags = try householdRows(fixture.store, "tags")
        #expect(tags.map { $0["id"] } == ["t-power".databaseValue, "tag-1".databaseValue])
        #expect(tags.last?["normalized_name"] == "café".databaseValue)
        #expect(try householdCount(fixture.store, "item_tags", where: "item_id = 'i1'") == 2)
    }

    @Test("an item create resets the local container's look to box, even the drop zone's, and keeps its kind")
    func dropZoneContainerBecomesBox() async throws {
        let fixture = try ShadowFixture { _ in
            .json(201, householdItemJSON(id: "i1", containerId: "drop-zone", spaceId: "drop-zone-space", containerShortCode: ""))
        }
        _ = try await fixture.repos.items.create(ItemDraft(containerId: "drop-zone"))
        let container = try #require(try householdRows(fixture.store, "containers").first { $0["id"] == "drop-zone".databaseValue })
        #expect(container["visual_type"] == "box".databaseValue)
        #expect(container["short_code"] == "CTR-DROP".databaseValue)
        #expect(container["kind"] == "system".databaseValue)
        #expect(container["name"] == "Box".databaseValue)
    }

    @Test("a mirror runs in one transaction: a failing container leaves the space untouched")
    func graphIsAtomic() async throws {
        let fixture = try ShadowFixture { _ in
            .json(201, householdItemJSON(id: "i1", containerId: "c-new", spaceId: "s-new", containerShortCode: "BOX-TAKN"))
        }
        let local = try await fixture.local.spaces.create(CreateSpaceInput(name: "Mine", icon: "", color: ""))
        try fixture.exec("INSERT INTO containers (id, space_id, name, visual_type, short_code, created_at, updated_at) VALUES ('c-mine', '\(local.id)', NULL, 'box', 'BOX-TAKN', 1, 1)")
        _ = try await fixture.repos.items.create(ItemDraft(containerId: "c-new"))
        #expect(fixture.shadowFailures.count == 1)
        // RN would have kept the space upsert that ran before the container failed.
        #expect(try householdCount(fixture.store, "spaces", where: "id = 's-new'") == 0)
        #expect(try householdCount(fixture.store, "items") == 0)
    }

    @Test("an item update mirrors the row only, leaving tags and photos alone")
    func itemUpdateRowOnly() async throws {
        let counter = Mutex(0)
        let fixture = try ShadowFixture { _ in
            let call = counter.withLock { $0 += 1; return $0 }
            return call == 1
                ? .json(201, householdItemJSON(id: "i1", photoId: "p1", photoUri: "r2:p1", tags: ["a"]))
                : .json(200, #"{"id":"i1","containerId":"c1","name":"Renamed","category":"Tools","quantity":4,"notes":null,"createdAt":10,"updatedAt":20}"#)
        }
        _ = try await fixture.repos.items.create(ItemDraft(containerId: "c1", name: "Cable"))
        _ = try await fixture.repos.items.update("i1", UpdateItemInput(name: "Renamed", tags: []))
        let row = try #require(try householdRows(fixture.store, "items").first)
        #expect(row["name"] == "Renamed".databaseValue)
        #expect(row["search_text"] == "renamed tools".databaseValue)
        #expect(row["updated_at"] == 20.databaseValue)
        #expect(row["created_at"] == 10.databaseValue)
        #expect(try householdCount(fixture.store, "item_tags") == 1)
        #expect(try householdCount(fixture.store, "item_photos") == 1)
    }

    @Test("deletes mirror only what the server deleted")
    func deletes() async throws {
        let fixture = try ShadowFixture { request in
            request.path.hasSuffix("/gone") ? .json(404, #"{"error":"not_found"}"#) : .json(200, #"{"deleted":true,"orphanedPhotoUris":[]}"#)
        }
        let space = try await fixture.local.spaces.create(CreateSpaceInput(name: "A", icon: "", color: ""))
        let container = try await fixture.local.containers.create(CreateContainerInput(spaceId: space.id, visualType: .box))
        let item = try await fixture.local.items.create(ItemDraft(containerId: container.id, name: "x"))
        _ = try await fixture.repos.items.delete("gone")
        _ = try await fixture.repos.items.delete(item.id)
        #expect(try householdCount(fixture.store, "items") == 0)
        _ = try await fixture.repos.containers.delete(container.id)
        #expect(try householdCount(fixture.store, "containers", where: "kind = 'normal'") == 0)
        _ = try await fixture.repos.spaces.delete("gone")
        #expect(try householdCount(fixture.store, "spaces", where: "kind = 'normal'") == 1)
        _ = try await fixture.repos.spaces.delete(space.id)
        #expect(try householdCount(fixture.store, "spaces", where: "kind = 'normal'") == 0)
    }

    @Test("a label binding replaces any binding on its token or container; unbinding removes the container's")
    func labels() async throws {
        let token = "0123456789abcdef0123456789abcdef"
        let fixture = try ShadowFixture { request in
            switch request.method {
            case "DELETE": request.path.contains("c9") ? .json(404, #"{"error":"not_found"}"#) : .status(204)
            default: .json(200, #"{"id":"q-new","token":"\#(token)","containerId":"c2","createdAt":3,"updatedAt":3}"#)
            }
        }
        let space = try await fixture.local.spaces.create(CreateSpaceInput(name: "A", icon: "", color: ""))
        try fixture.exec("""
            INSERT INTO containers (id, space_id, name, visual_type, short_code, created_at, updated_at) VALUES
              ('c1', '\(space.id)', NULL, 'box', 'BOX-0001', 1, 1), ('c2', '\(space.id)', NULL, 'box', 'BOX-0002', 1, 1);
            INSERT INTO qr_bindings (id, token, container_id, created_at, updated_at) VALUES
              ('q-old', '\(token)', 'c1', 1, 1), ('q-c2', 'ffffffffffffffffffffffffffffffff', 'c2', 1, 1);
            """)
        _ = try await fixture.repos.qr.bind(token: token, containerId: "c2")
        #expect(try householdRows(fixture.store, "qr_bindings").map { $0["id"] } == ["q-new".databaseValue])
        _ = try await fixture.repos.qr.unbind("c9")
        #expect(try householdCount(fixture.store, "qr_bindings") == 1)
        _ = try await fixture.repos.qr.unbind("c2")
        #expect(try householdCount(fixture.store, "qr_bindings") == 0)
    }
}
