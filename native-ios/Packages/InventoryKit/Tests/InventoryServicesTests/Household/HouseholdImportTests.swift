import Foundation
import GRDB
import InventoryCore
import InventoryNetwork
import InventoryStorage
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryServices

// RN: src/services/household/__tests__/import.test.ts, plus the 04 §11.2-11.3 rules it does not
// pin: the dump's exact shape, the photo fallback, failures, and the items-count fallback.

private let photoId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

/// RN `repos.spaces.create(Garage)`, a box in it, and an item.
private func seedGarage(_ local: LocalRepositories, item: ItemDraft? = nil) async throws -> (space: Space, container: Container) {
    let space = try await local.spaces.create(CreateSpaceInput(name: "Garage", icon: "🚗", color: "#5B8DEF"))
    let container = try await local.containers.create(CreateContainerInput(spaceId: space.id, visualType: .box))
    if var item {
        item.containerId = container.id
        _ = try await local.items.create(item)
    }
    return (space, container)
}

private func importer(
    _ server: StubServer,
    photos: HouseholdFakePhotos,
    telemetry: RecordingTelemetry = RecordingTelemetry(),
    fallback: HouseholdImporter.PhotoFallback? = nil
) -> HouseholdImporter {
    HouseholdImporter(
        session: householdTestSession,
        client: server.householdClient(),
        photos: photos,
        makeFallback: { fallback },
        telemetry: TelemetryReporter(sink: telemetry)
    )
}

@Suite("household import")
struct HouseholdImportTests {
    @Test("collects local rows including system drop-zone")
    func collectsLocalRowsIncludingSystemDropZone() async throws {
        let local = try householdFreshLocal()
        _ = try await seedGarage(local, item: ItemDraft(containerId: "", name: "Drill"))
        let dump = try await HouseholdDumpCollector.collectHouseholdDump(from: local.store)
        #expect(dump.spaces.contains { $0.id == "drop-zone-space" })
        #expect(dump.containers.contains { $0.id == "drop-zone" })
        #expect(dump.items.contains { $0.name == "Drill" })
    }

    @Test("POSTs the dump then PUTs each photo")
    func postsTheDumpThenPutsEachPhoto() async throws {
        let local = try householdFreshLocal()
        _ = try await seedGarage(local, item: ItemDraft(containerId: "", name: "Cable", photo: ItemPhotoInput(id: photoId, uri: "file:///photos/cable.webp")))
        let server = StubServer { request in
            if request.path == "/v1/import" { return .json(200, #"{"ok":true,"items":1,"photos":1}"#) }
            if request.path.hasPrefix("/v1/photos/") { return .json(201, #"{"id":"\#(photoId)"}"#) }
            return .json(404, "{}")
        }
        let photos = HouseholdFakePhotos(["file:///photos/cable.webp": Data([1, 2, 3, 4])])
        let result = try await importer(server, photos: photos).importLocalInventory(from: local.store)

        #expect(result.items == 1)
        #expect(result.photosUploaded == 1)
        let lines = server.requests.map(\.line)
        #expect(lines.contains { $0.hasPrefix("POST ") && $0.hasSuffix("/v1/import") })
        #expect(lines.contains { $0.hasPrefix("PUT ") && $0.contains("/v1/photos/") })
    }
}

@Suite("household import (04 §11)")
struct HouseholdImportRulesTests {
    @Test("the dump carries every row of the seven tables, NULL columns as explicit nulls, photo URIs left out")
    func dumpShape() async throws {
        let local = try householdFreshLocal()
        let (space, container) = try await seedGarage(local)
        let item = try await local.items.create(ItemDraft(
            containerId: container.id, name: "Cable", category: "Power", tags: ["usb"],
            photo: ItemPhotoInput(id: photoId, uri: "file:///p.webp", thumbUri: "file:///p-thumb.webp")
        ))
        _ = try await local.qr.createAndBind(container.id)

        let dump = try await HouseholdDumpCollector.collectHouseholdDump(from: local.store)
        #expect(Set(dump.spaces.map(\.id)) == ["drop-zone-space", space.id])
        #expect(dump.spaces.first { $0.id == "drop-zone-space" }?.kind == .system)
        #expect(dump.containers.first { $0.id == container.id }?.name == nil)
        #expect(dump.containers.first { $0.id == "drop-zone" }?.visualType == .other)
        #expect(dump.items.map(\.id) == [item.id])
        #expect(dump.items.first?.searchText == "cable power")
        #expect(dump.tags.map(\.normalizedName) == ["usb"])
        #expect(dump.itemTags == [HouseholdDump.ItemTagRow(itemId: item.id, tagId: dump.tags[0].id)])
        #expect(dump.qrBindings.map(\.containerId) == [container.id])
        #expect(dump.photos == [HouseholdDump.PhotoRow(id: photoId, itemId: item.id, width: nil, height: nil, byteSize: nil, createdAt: item.createdAt)])

        let json = try #require(JSONValue.parse(try JSONEncoder().encode(dump)))
        let photo = try #require(json.objectValue?["photos"]?.arrayValue?.first?.objectValue)
        #expect(photo["width"] == .null)
        #expect(photo["uri"] == nil)
        let row = try #require(json.objectValue?["containers"]?.arrayValue?.first { $0.objectValue?["id"] == .string(container.id) }?.objectValue)
        #expect(row["name"] == .null)

        #expect(try await HouseholdDumpCollector.localPhotoUris(from: local.store) == [photoId: "file:///p.webp"])
    }

    @Test("a photo whose file is gone comes from the backup; one in neither place counts as missing")
    func photoFallback() async throws {
        let local = try householdFreshLocal()
        let (_, container) = try await seedGarage(local)
        for (index, id) in ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"].enumerated() {
            _ = try await local.items.create(ItemDraft(containerId: container.id, name: "Item \(index)", photo: ItemPhotoInput(id: id, uri: "file:///\(index).webp")))
        }
        let server = StubServer { request in
            request.path == "/v1/import" ? .json(200, #"{"ok":true,"items":3,"photos":3}"#) : .status(201)
        }
        let photos = HouseholdFakePhotos(["file:///0.webp": Data([0])])
        let asked = Mutex<[String]>([])
        let result = try await importer(server, photos: photos) { id in
            asked.withLock { $0.append(id) }
            return id.hasPrefix("2") ? Data([2]) : nil
        }.importLocalInventory(from: local.store)

        #expect(result == HouseholdImportResult(items: 3, photos: 3, photosUploaded: 2, photosMissing: 1))
        #expect(Set(asked.withLock { $0 }) == ["22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"])
        let puts = server.requests.filter { $0.method == "PUT" }
        #expect(Set(puts.map(\.path)) == ["/v1/photos/11111111-1111-4111-8111-111111111111", "/v1/photos/22222222-2222-4222-8222-222222222222"])
        #expect(puts.allSatisfy { $0.header("content-type") == "application/octet-stream" })
    }

    @Test("the backup fallback is built only after the dump was accepted")
    func fallbackAfterPost() async throws {
        let local = try householdFreshLocal()
        let server = StubServer { _ in .json(500, #"{"error":"UNIQUE constraint failed: tags.normalized_name"}"#) }
        let built = Mutex(false)
        let importer = HouseholdImporter(
            session: householdTestSession, client: server.householdClient(), photos: HouseholdFakePhotos(),
            makeFallback: {
                built.withLock { $0 = true }
                return nil
            }
        )
        await #expect(throws: HouseholdHttpError(status: 500, code: "UNIQUE constraint failed: tags.normalized_name")) {
            _ = try await importer.importLocalInventory(from: local.store)
        }
        #expect(!built.withLock { $0 })
    }

    @Test("a refused photo counts as missing; a photo upload that gets no answer aborts the import")
    func photoUploadOutcomes() async throws {
        let local = try householdFreshLocal()
        _ = try await seedGarage(local, item: ItemDraft(containerId: "", name: "Cable", photo: ItemPhotoInput(id: photoId, uri: "file:///p.webp")))
        let photos = HouseholdFakePhotos(["file:///p.webp": Data()])

        let refusing = StubServer { request in
            request.path == "/v1/import" ? .json(200, #"{"ok":true,"items":1,"photos":1}"#) : .json(400, #"{"error":"empty_upload"}"#)
        }
        let refused = try await importer(refusing, photos: photos).importLocalInventory(from: local.store)
        #expect(refused.photosUploaded == 0)
        #expect(refused.photosMissing == 1)
        // An empty file is still bytes (RN `if (!bytes)` is false for an empty array).
        #expect(refusing.requests.last?.method == "PUT")

        let silent = StubServer { request in
            request.path == "/v1/import" ? .json(200, #"{"ok":true,"items":1,"photos":1}"#) : .failure(.networkConnectionLost, delay: nil)
        }
        let telemetry = RecordingTelemetry()
        await #expect(throws: HouseholdHttpError(status: 0, code: "offline")) {
            _ = try await importer(silent, photos: photos, telemetry: telemetry).importLocalInventory(from: local.store)
        }
        #expect(!telemetry.names.contains("household_imported"))
    }

    @Test("the result's items come from the server, or from the dump when the server sends no number; logs household_imported")
    func itemsCountFallback() async throws {
        let local = try householdFreshLocal()
        _ = try await seedGarage(local, item: ItemDraft(containerId: "", name: "A"))
        let server = StubServer { _ in .json(200, #"{"ok":true,"items":"many"}"#) }
        let telemetry = RecordingTelemetry()
        let result = try await importer(server, photos: HouseholdFakePhotos(), telemetry: telemetry).importLocalInventory(from: local.store)
        #expect(result == HouseholdImportResult(items: 1, photos: 0, photosUploaded: 0, photosMissing: 0))
        #expect(telemetry.entries == [RecordingTelemetry.Entry(level: "event", name: "household_imported", payload: ["itemCount": .int(1)])])

        let counted = StubServer { _ in .json(200, #"{"ok":true,"items":7}"#) }
        #expect(try await importer(counted, photos: HouseholdFakePhotos()).importLocalInventory(from: local.store).items == 7)
    }

    @Test("the import posts the dump to the session's origin with its token and a JSON body")
    func importRequest() async throws {
        let local = try householdFreshLocal()
        let server = StubServer { _ in .json(200, #"{"ok":true}"#) }
        _ = try await importer(server, photos: HouseholdFakePhotos()).importLocalInventory(from: local.store)
        let request = try #require(server.lastRequest)
        #expect(request.line == "POST https://inventory.wystudio.be/v1/import")
        #expect(request.header("authorization") == "Bearer tok")
        #expect(request.jsonObject.keys.sorted() == ["containers", "itemTags", "items", "photos", "qrBindings", "spaces", "tags"])
    }

    @Test("the backup fallback needs a recovery code that decodes to 16 bytes")
    func backupFallbackNeedsAnAccount() async throws {
        let config = AppConfig(infoDictionary: [:])
        let none = HouseholdImporter.backupPhotoFallback(recoveryCodes: RecoveryCodeStore(keychain: InMemoryKeychain()), config: config)
        #expect(await none() == nil)
        let short = HouseholdImporter.backupPhotoFallback(
            recoveryCodes: RecoveryCodeStore(keychain: InMemoryKeychain([KeychainKey.recoveryCode: "ABC"])), config: config
        )
        #expect(await short() == nil)
        let code = CrockfordBase32.encode([UInt8](repeating: 7, count: 16))
        let valid = HouseholdImporter.backupPhotoFallback(
            recoveryCodes: RecoveryCodeStore(keychain: InMemoryKeychain([KeychainKey.recoveryCode: code])), config: config
        )
        let download = try #require(await valid())
        // No sync endpoint in this config: every download is not_configured, which reads as no bytes.
        #expect(await download(photoId) == nil)
    }
}
