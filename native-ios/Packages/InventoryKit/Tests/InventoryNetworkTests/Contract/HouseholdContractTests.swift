import Foundation
import InventoryCore
import Testing
@testable import InventoryNetwork

// Every household endpoint against answers recorded from home-server/src
// (Fixtures/generator/household-contract.mts). Each test sends the request through
// the Swift client, checks it is the request the RN client sends (method, path,
// headers, JSON), and decodes the real server's answer.

private func client(_ server: StubServer, token: String? = nil, contract: HouseholdContract, hub: ReachabilityHub? = nil, makeId: (@Sendable () -> String)? = nil) -> HouseholdClient {
    HouseholdClient(
        origin: contract.origin,
        token: token ?? contract.token,
        transport: server.transport,
        reachability: hub,
        telemetry: TelemetryRecorder().telemetry,
        makeId: makeId ?? { newId() }
    )
}

/// Runs `call` against a replay of the named exchanges and checks each request.
private func exchange<T>(
    _ names: String...,
    token: String? = nil,
    hub: ReachabilityHub? = nil,
    makeId: (@Sendable () -> String)? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ call: (HouseholdClient, HouseholdContract) async throws -> T
) async throws -> T {
    let contract = try HouseholdContract.load()
    let recorded = try names.map(contract.exchange)
    let server = replay(recorded)
    let result = try await call(client(server, token: token, contract: contract, hub: hub, makeId: makeId), contract)
    let sent = server.requests
    #expect(sent.count == recorded.count, "requests sent", sourceLocation: sourceLocation)
    for (request, expected) in zip(sent, recorded) {
        expectRequest(request, matches: expected, sourceLocation: sourceLocation)
        #expect(request.header("x-inventory-key") == nil, "household requests never carry the app key", sourceLocation: sourceLocation)
    }
    return result
}

private func expectHTTPError(
    _ status: Int,
    _ code: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ work: () async throws -> Void
) async {
    do {
        try await work()
        Issue.record("expected HouseholdHttpError(\(status), \(code))", sourceLocation: sourceLocation)
    } catch let error as HouseholdHttpError {
        #expect(error == HouseholdHttpError(status: status, code: code), sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("Household contract: pairing and phones")
struct HouseholdPairingContractTests {
    @Test("health answers exactly ok and the contract version, without a token")
    func health() async throws {
        let health = try await exchange("health") { client, _ in try await client.health() }
        #expect(health == HouseholdHealth(ok: true, contractVersion: 1))
    }

    @Test("pairing trims the name, strips trailing slashes and keeps the server's origin")
    func pair() async throws {
        let contract = try HouseholdContract.load()
        let server = replay([try contract.exchange("pair")])
        let unpaired = HouseholdClient(
            origin: contract.origin + "//", token: nil, transport: server.transport,
            telemetry: TelemetryRecorder().telemetry
        )
        let pairing = try await unpaired.pair(bootstrapSecret: "MMWKY-M2H78-ABCDE-FGHJK-MNPQR-S", deviceName: "  Kitchen iPhone  ")
        expectRequest(server.lastRequest, matches: try contract.exchange("pair"))
        #expect(server.lastRequest?.header("authorization") == nil)
        #expect(pairing == HouseholdPairing(
            origin: "https://inventory.wystudio.be",
            token: contract.token,
            deviceId: try contract.id("deviceId"),
            deviceName: "Kitchen iPhone",
            householdName: "Home"
        ))
    }

    @Test("a refused household code is a 401 the reachability channel reads as an answer")
    func pairRefused() async throws {
        let hub = ReachabilityHub()
        let updates = hub.updates()
        await expectHTTPError(401, "unauthorized") {
            _ = try await exchange("pairRefused", hub: hub) { client, _ in
                try await client.pair(bootstrapSecret: "AAAAA-AAAAA-AAAAA-AAAAA-AAAAA-A", deviceName: "Pixel")
            }
        }
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .ok)
    }

    @Test("lists the household's phones, oldest first")
    func devices() async throws {
        let contract = try HouseholdContract.load()
        let devices = try await exchange("devices") { client, _ in try await client.listDevices() }
        #expect(devices.map(\.id) == [try contract.id("deviceId"), try contract.id("otherDeviceId")])
        #expect(devices.map(\.name) == ["Kitchen iPhone", "Anna’s iPhone"])
        #expect(devices.allSatisfy { $0.createdAt > 0 && $0.lastSeenAt != nil })
    }

    @Test("an unknown token is unauthorized")
    func devicesUnauthorized() async throws {
        let hub = ReachabilityHub()
        let updates = hub.updates()
        await expectHTTPError(401, "unauthorized") {
            _ = try await exchange("devicesUnauthorized", token: String(repeating: "f", count: 64), hub: hub) { client, _ in
                try await client.listDevices()
            }
        }
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .unauthorized)
    }

    @Test("removes a phone, and treats one already gone as removed")
    func revokeDevice() async throws {
        let contract = try HouseholdContract.load()
        let other = try contract.id("otherDeviceId")
        try await exchange("revokeDevice", "revokeDeviceMissing") { client, _ in
            try await client.revokeDevice(id: other)
            try await client.revokeDevice(id: other, timeout: .seconds(5))
        }
    }

    @Test("a removed phone's token is refused")
    func revokedTokenRefused() async throws {
        let hub = ReachabilityHub()
        let updates = hub.updates()
        await expectHTTPError(401, "unauthorized") {
            _ = try await exchange("revokedTokenRefused", token: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210", hub: hub) { client, _ in
                try await client.listSpaces()
            }
        }
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .unauthorized)
    }
}

@Suite("Household contract: spaces")
struct HouseholdSpaceContractTests {
    @Test("creates a space")
    func createSpace() async throws {
        let contract = try HouseholdContract.load()
        let space = try await exchange("createSpace") { client, _ in
            try await client.createSpace(.init(name: "Garage", icon: "🧰", color: "#7A9E7E"))
        }
        let body = try contract.responseJSON("createSpace")
        #expect(space == Space(
            id: try contract.id("spaceId"), name: "Garage", icon: "🧰", color: "#7A9E7E",
            createdAt: try #require(body["createdAt"]?.int64), updatedAt: try #require(body["updatedAt"]?.int64)
        ))
    }

    @Test("an empty field is invalid_body")
    func createSpaceInvalid() async throws {
        await expectHTTPError(400, "invalid_body") {
            _ = try await exchange("createSpaceInvalid") { client, _ in
                try await client.createSpace(.init(name: "", icon: "x", color: "y"))
            }
        }
    }

    @Test("reads a space, and nil for one that is gone")
    func getSpace() async throws {
        let contract = try HouseholdContract.load()
        let id = try contract.id("spaceId")
        let (found, missing) = try await exchange("getSpace", "getSpaceMissing") { client, _ in
            (try await client.space(id: id), try await client.space(id: "nope"))
        }
        #expect(found?.name == "Garage")
        #expect(missing == nil)
    }

    @Test("renames a space, and nil for one that is gone")
    func updateSpace() async throws {
        let contract = try HouseholdContract.load()
        let id = try contract.id("spaceId")
        let (renamed, missing) = try await exchange("updateSpace", "updateSpaceMissing") { client, _ in
            (try await client.updateSpace(id: id, .init(name: "Big garage")), try await client.updateSpace(id: "nope", .init(name: "x")))
        }
        #expect(renamed?.name == "Big garage")
        #expect(renamed?.icon == "🧰")
        #expect(missing == nil)
    }

    @Test("the drop zone's space answers Hono's plain-text 500, read as invalid_json")
    func updateDropZoneSpace() async throws {
        await expectHTTPError(500, "invalid_json") {
            _ = try await exchange("updateDropZoneSpace") { client, _ in
                try await client.updateSpace(id: DropZone.spaceId, .init(name: "x"))
            }
        }
    }

    @Test("lists spaces with counts, by name")
    func listSpaces() async throws {
        let spaces = try await exchange("listSpaces") { client, _ in try await client.listSpaces() }
        // The drawer has moved to the attic by now; the drill is in the tool chest.
        #expect(spaces.map(\.name) == ["Attic", "Big garage"])
        #expect(spaces.map(\.containerCount) == [1, 1])
        #expect(spaces.map(\.itemCount) == [0, 1])
    }

    @Test("deletes a space, and reports one already gone")
    func deleteSpace() async throws {
        let contract = try HouseholdContract.load()
        let id = try contract.id("secondSpaceId")
        let (deleted, missing) = try await exchange("deleteSpace", "deleteSpaceMissing") { client, _ in
            (try await client.deleteSpace(id: id), try await client.deleteSpace(id: id))
        }
        #expect(deleted == HouseholdDeleteResult(deleted: true, orphanedPhotoUris: []))
        #expect(missing == .alreadyGone)
    }
}

@Suite("Household contract: containers")
struct HouseholdContainerContractTests {
    @Test("creates a named container; the server makes the short code")
    func createContainer() async throws {
        let contract = try HouseholdContract.load()
        let spaceId = try contract.id("spaceId")
        let container = try await exchange("createContainer") { client, _ in
            try await client.createContainer(.init(spaceId: spaceId, visualType: .box, name: "Tool chest"))
        }
        #expect(container.id == (try contract.id("containerId")))
        #expect(container.name == "Tool chest")
        #expect(container.visualType == .box)
        #expect(container.shortCode == (try contract.responseJSON("createContainer")["shortCode"]?.string))
        #expect(container.shortCode.hasPrefix("BOX-"))
    }

    @Test("creates an unnamed container without sending a name key")
    func createContainerUnnamed() async throws {
        let contract = try HouseholdContract.load()
        let spaceId = try contract.id("spaceId")
        let container = try await exchange("createContainerUnnamed") { client, _ in
            try await client.createContainer(.init(spaceId: spaceId, visualType: .drawer))
        }
        #expect(container.name == nil)
        #expect(container.visualType == .drawer)
    }

    @Test("reads a container with counts, and nil for one that is gone")
    func getContainer() async throws {
        let contract = try HouseholdContract.load()
        let id = try contract.id("containerId")
        let (found, missing) = try await exchange("getContainer", "getContainerMissing") { client, _ in
            (try await client.container(id: id), try await client.container(id: "nope"))
        }
        #expect(found?.name == "Tool chest")
        #expect(found?.itemCount == 0)
        #expect(found?.qrToken == nil)
        #expect(missing == nil)
    }

    @Test("clears a container's name with an explicit null")
    func updateContainerClearName() async throws {
        let contract = try HouseholdContract.load()
        let id = try contract.id("containerId")
        let updated = try await exchange("updateContainerClearName") { client, _ in
            try await client.updateContainer(id: id, .init(name: .clear))
        }
        #expect(updated?.name == nil)
        #expect(updated?.visualType == .box)
    }

    @Test("renames, retypes and moves a container")
    func updateContainerMove() async throws {
        let contract = try HouseholdContract.load()
        let id = try contract.id("secondContainerId")
        let attic = try contract.id("secondSpaceId")
        let updated = try await exchange("updateContainerMove") { client, _ in
            try await client.updateContainer(id: id, .init(name: .set("Bits"), visualType: .bin, spaceId: attic))
        }
        #expect(updated?.name == "Bits")
        #expect(updated?.visualType == .bin)
        #expect(updated?.spaceId == attic)
    }

    @Test("lists a space's containers and every container with its space")
    func listContainers() async throws {
        let contract = try HouseholdContract.load()
        let spaceId = try contract.id("spaceId")
        let (inSpace, all) = try await exchange("listContainersBySpace", "listAllContainers") { client, _ in
            (try await client.listContainers(spaceId: spaceId), try await client.listAllContainers())
        }
        #expect(inSpace.map(\.id) == [try contract.id("containerId")])
        #expect(inSpace.first?.itemCount == 1)
        #expect(all.map(\.spaceName) == ["Attic", "Big garage"])
        #expect(all.map(\.name) == ["Bits", nil])
    }

    @Test("deletes a container, and reports one already gone")
    func deleteContainer() async throws {
        let contract = try HouseholdContract.load()
        let id = try contract.id("secondContainerId")
        let (deleted, missing) = try await exchange("deleteContainer", "deleteContainerMissing") { client, _ in
            (try await client.deleteContainer(id: id), try await client.deleteContainer(id: id))
        }
        #expect(deleted == HouseholdDeleteResult(deleted: true, orphanedPhotoUris: []))
        #expect(missing == .alreadyGone)
    }
}

@Suite("Household contract: items and photos")
struct HouseholdItemContractTests {
    private static let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==") ?? Data()

    @Test("uploads photo bytes under a new id, then creates the item with that photo")
    func uploadThenCreate() async throws {
        let contract = try HouseholdContract.load()
        let photoId = try contract.id("uploadPhotoId")
        let containerId = try contract.id("containerId")
        let created = try await exchange("uploadPhoto", "createItem", makeId: { photoId }) { client, _ in
            let photo = try await client.uploadPhoto(Self.pixel)
            #expect(photo.id == photoId)
            #expect(photo.uri == "r2:household/primary/photos/\(photoId).webp")
            #expect(photo.thumbUri == "r2:household/primary/photos/\(photoId)-thumb.webp")
            #expect(photo.width == 1 && photo.height == 1)
            #expect(photo.byteSize != nil)
            return try await client.createItem(.init(
                containerId: containerId, name: "Cordless Drill", category: "Power Tools", quantity: 2,
                tags: ["dewalt", "18v"], photo: photo.reference
            ))
        }
        #expect(created.id == (try contract.id("itemId")))
        #expect(created.name == "Cordless Drill")
        #expect(created.quantity == 2)
        #expect(created.photoId == photoId)
        #expect(created.photoUri == "r2:household/primary/photos/\(photoId).webp")
        // Tags come back in tag-id order, not the order sent.
        #expect(Set(created.tags) == ["dewalt", "18v"])
        #expect(created.spaceName == "Big garage")
        // The chest's name was cleared earlier in the recorded session.
        #expect(created.containerName == nil)
        #expect(created.containerShortCode.hasPrefix("BOX-"))
    }

    @Test("a photo id that is not a UUID, and an empty photo, are refused")
    func photoRefusals() async throws {
        await expectHTTPError(400, "invalid_id") {
            _ = try await exchange("uploadPhotoInvalidId", makeId: { "not-a-uuid" }) { client, _ in
                try await client.uploadPhoto(Self.pixel)
            }
        }
        let contract = try HouseholdContract.load()
        let photoId = try contract.id("uploadPhotoId")
        await expectHTTPError(400, "empty_upload") {
            _ = try await exchange("uploadPhotoEmpty", makeId: { photoId }) { client, _ in
                try await client.uploadPhoto(Data())
            }
        }
    }

    @Test("files an unnamed capture in the drop zone without sending a name")
    func createItemUnnamed() async throws {
        let item = try await exchange("createItemUnnamed") { client, _ in
            try await client.createItem(.init(containerId: DropZone.containerId))
        }
        #expect(item.name == "")
        #expect(item.quantity == 1)
        #expect(item.containerId == DropZone.containerId)
    }

    @Test("an explicitly blank name and a photo the store never saw are refused")
    func createItemRefusals() async throws {
        let contract = try HouseholdContract.load()
        let containerId = try contract.id("containerId")
        await expectHTTPError(400, "Item name is required.") {
            _ = try await exchange("createItemBlankName") { client, _ in
                try await client.createItem(.init(containerId: containerId, name: "   "))
            }
        }
        await expectHTTPError(400, "photo_missing") {
            _ = try await exchange("createItemMissingPhoto") { client, _ in
                try await client.createItem(.init(
                    containerId: containerId, name: "Ghost",
                    photo: .init(id: "00000000-0000-4000-8000-000000000000", uri: "r2:household/primary/photos/x.webp")
                ))
            }
        }
    }

    @Test("reads an item with context, and nil for one that is gone")
    func getItem() async throws {
        let contract = try HouseholdContract.load()
        let id = try contract.id("itemId")
        let (found, missing) = try await exchange("getItem", "getItemMissing") { client, _ in
            (try await client.item(id: id), try await client.item(id: "nope"))
        }
        #expect(found?.name == "Cordless Drill")
        #expect(found?.photoThumbUri?.hasPrefix("r2:") == true)
        #expect(missing == nil)
    }

    @Test("lists a container's items, the drop zone and the recent items")
    func listItems() async throws {
        let contract = try HouseholdContract.load()
        let containerId = try contract.id("containerId")
        let (inContainer, unsorted, recent) = try await exchange("listItemsByContainer", "listUnsorted", "listRecent") { client, _ in
            (
                try await client.listItems(containerId: containerId),
                try await client.listUnsortedItems(),
                try await client.listRecentItems()
            )
        }
        #expect(inContainer.map(\.name) == ["Cordless Drill"])
        #expect(unsorted.map(\.id) == [try contract.id("unnamedItemId")])
        #expect(recent.map(\.id) == [try contract.id("unnamedItemId"), try contract.id("itemId")])
    }

    @Test("patches an item: a null category clears it, absent keys are left alone")
    func updateItem() async throws {
        let contract = try HouseholdContract.load()
        let id = try contract.id("itemId")
        let stamp = try contract.number("itemUpdatedAt")
        let updated = try await exchange("updateItem") { client, _ in
            try await client.updateItem(id: id, .init(
                name: "Hammer drill", category: .clear, quantity: 3, notes: .set("Left shelf"),
                tags: ["bosch"], expectedUpdatedAt: stamp
            ))
        }
        let item = try #require(updated)
        #expect(item.name == "Hammer drill")
        #expect(item.category == nil)
        #expect(item.quantity == 3)
        #expect(item.notes == "Left shelf")
        #expect(item.updatedAt == (try contract.number("updatedAt")))
    }

    @Test("a stale updatedAt is a ConflictError carrying the current stamp")
    func updateItemConflict() async throws {
        let contract = try HouseholdContract.load()
        let id = try contract.id("itemId")
        let stamp = try contract.number("itemUpdatedAt")
        let current = ConflictError(updatedAt: try contract.number("updatedAt"))
        await #expect(throws: current) {
            _ = try await exchange("updateItemConflict") { client, _ in
                try await client.updateItem(id: id, .init(name: "Stale", expectedUpdatedAt: stamp))
            }
        }
    }

    @Test("sets a quantity of zero, moves an item, and nil for one that is gone")
    func moreItemPatches() async throws {
        let contract = try HouseholdContract.load()
        let id = try contract.id("itemId")
        let unnamed = try contract.id("unnamedItemId")
        let drawer = try contract.id("secondContainerId")
        let (zero, moved, missing) = try await exchange("updateItemQuantityZero", "updateItemMove", "updateItemMissing") { client, _ in
            (
                try await client.updateItem(id: id, .init(quantity: 0)),
                try await client.updateItem(id: unnamed, .init(containerId: drawer)),
                try await client.updateItem(id: "nope", .init(name: "x"))
            )
        }
        #expect(zero?.quantity == 0)
        #expect(moved?.containerId == drawer)
        #expect(missing == nil)
    }

    @Test("deletes an item and returns its orphaned photo URIs; a second delete reports it gone")
    func deleteItem() async throws {
        let contract = try HouseholdContract.load()
        let id = try contract.id("itemId")
        let photoId = try contract.id("uploadPhotoId")
        let (deleted, missing) = try await exchange("deleteItem", "deleteItemMissing") { client, _ in
            (try await client.deleteItem(id: id), try await client.deleteItem(id: id))
        }
        #expect(deleted.deleted)
        #expect(deleted.orphanedPhotoUris == [
            "r2:household/primary/photos/\(photoId).webp", "r2:household/primary/photos/\(photoId)-thumb.webp",
        ])
        #expect(missing == .alreadyGone)
    }

    @Test("downloads a photo's thumbnail and full image, and nil for one the store does not have")
    func photos() async throws {
        let contract = try HouseholdContract.load()
        let photoId = try contract.id("uploadPhotoId")
        let (thumb, full, missing) = try await exchange("getPhotoThumb", "getPhotoFull", "getPhotoMissing") { client, _ in
            (
                try await client.photo(id: photoId, thumbnail: true),
                try await client.photo(id: photoId, thumbnail: false),
                try await client.photo(id: "00000000-0000-4000-8000-000000000000", thumbnail: false)
            )
        }
        #expect(thumb == (try contract.exchange("getPhotoThumb")).response.body)
        #expect(full == (try contract.exchange("getPhotoFull")).response.body)
        #expect(thumb.map(ImageMediaType.sniff) == "image/webp")
        #expect(missing == nil)
    }

    @Test("imports a dump, then uploads its photo under the phone's own id")
    func importDump() async throws {
        let contract = try HouseholdContract.load()
        // RN's collectHouseholdDump output, read into the typed dump; sending it back must
        // give the same JSON, nulls included (the exchange checks the body).
        let dumpText = try #require(try contract.exchange("import").request.json)
        let dump = try JSONDecoder().decode(HouseholdDump.self, from: Data(dumpText.utf8))
        #expect(dump.spaces.map(\.kind) == [.system, .normal])
        #expect(dump.containers.first?.visualType == .other)
        #expect(dump.items.first?.category == nil)
        let photoId = try contract.id("importPhotoId")
        let (summary, stored) = try await exchange("import", "importPhoto") { client, _ in
            (try await client.importDump(dump), try await client.importPhoto(id: photoId, bytes: Self.pixel))
        }
        #expect(summary == HouseholdImportSummary(spaces: 2, containers: 2, items: 1, photos: 1))
        #expect(stored)
    }

    @Test("a photo row without dimensions goes as explicit nulls, which the server takes; missing keys fail the import")
    func importNullPhotoFields() async throws {
        let contract = try HouseholdContract.load()
        let photoId = try contract.id("nullPhotoId")
        let dumpText = try #require(try contract.exchange("import").request.json)
        let importedItem = try #require(try JSONDecoder().decode(HouseholdDump.self, from: Data(dumpText.utf8)).items.first?.id)
        let summary = try await exchange("importNullPhotoFields") { client, _ in
            try await client.importDump(HouseholdDump(photos: [
                .init(id: photoId, itemId: importedItem, width: nil, height: nil, byteSize: nil, createdAt: 1_767_225_600_000),
            ]))
        }
        #expect(summary == HouseholdImportSummary(spaces: 0, containers: 0, items: 0, photos: 1))
        // What leaving the keys out does to the real server (home-server/src/importer.ts:174-176).
        let omitted = try contract.exchange("importOmittedPhotoFields").response
        #expect(omitted.status == 400)
        #expect(omitted.text == #"{"error":"Provided value cannot be bound to SQLite parameter 5."}"#)
    }
}

@Suite("Household contract: search and labels")
struct HouseholdSearchContractTests {
    @Test("searches items, locations, and nothing for a blank query")
    func search() async throws {
        let (items, location, empty) = try await exchange("search", "searchLocation", "searchEmpty") { client, _ in
            (try await client.search("drill"), try await client.search("Big garage"), try await client.search(""))
        }
        #expect(items.terms == ["drill"])
        #expect(items.items.map(\.name) == ["Hammer drill"])
        #expect(items.items.first?.matchKind == .direct)
        #expect(location.terms == ["big", "garage"])
        #expect(location.locations.first?.kind == .space)
        #expect(location.locations.first?.title == "Big garage")
        #expect(empty == .empty)
    }

    @Test("creates and binds a label, then resolves scans of it, of an unknown label and of junk")
    func labels() async throws {
        let contract = try HouseholdContract.load()
        let containerId = try contract.id("containerId")
        let labelToken = try contract.id("labelToken")
        let (binding, bound, unknown, invalid) = try await exchange("createLabel", "scanBound", "scanUnknown", "scanInvalid") { client, _ in
            (
                try await client.createAndBindLabel(containerId: containerId),
                try await client.resolveScan("inventory://c/\(labelToken)"),
                try await client.resolveScan(String(repeating: "ab", count: 16)),
                try await client.resolveScan("hello")
            )
        }
        #expect(binding.token == labelToken)
        #expect(binding.containerId == containerId)
        guard case .bound(let container, let token) = bound else {
            Issue.record("expected a bound outcome, got \(bound)")
            return
        }
        #expect(container.id == containerId)
        #expect(token == labelToken)
        #expect(unknown == .unknown(token: String(repeating: "ab", count: 16)))
        #expect(invalid == .invalid(raw: "hello"))
    }

    @Test("binds a printed label; the drop zone refuses one")
    func bindLabel() async throws {
        let contract = try HouseholdContract.load()
        let drawer = try contract.id("secondContainerId")
        let printed = try contract.id("printedToken")
        let binding = try await exchange("bindLabel") { client, _ in
            try await client.bindLabel(token: printed, containerId: drawer)
        }
        #expect(binding.token == printed)
        #expect(binding.containerId == drawer)
        await expectHTTPError(400, "system_record") {
            _ = try await exchange("bindLabelDropZone") { client, _ in
                try await client.bindLabel(token: String(repeating: "ef", count: 16), containerId: DropZone.containerId)
            }
        }
    }

    @Test("unbinds a label: true on 204, false when there was none")
    func unbindLabel() async throws {
        let contract = try HouseholdContract.load()
        let containerId = try contract.id("containerId")
        let (first, second) = try await exchange("unbindLabel", "unbindLabelMissing") { client, _ in
            (try await client.unbindLabel(containerId: containerId), try await client.unbindLabel(containerId: containerId))
        }
        #expect(first)
        #expect(!second)
    }

    @Test("an unknown route answers Hono's plain-text 404, read as (404, invalid_json)")
    func unknownRoute() async throws {
        await expectHTTPError(404, "invalid_json") {
            _ = try await exchange("unknownRoute") { client, _ in
                try await client.request(HouseholdRequest(path: "/v1/nope"), as: IgnoredBody.self)
            }
        }
    }
}
