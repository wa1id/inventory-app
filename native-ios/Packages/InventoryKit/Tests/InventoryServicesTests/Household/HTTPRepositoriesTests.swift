import Foundation
import InventoryCore
import InventoryNetwork
import InventoryStorage
import InventoryTestSupport
import Testing
@testable import InventoryServices

// RN: src/services/household/__tests__/client.test.ts (`createHttpRepositories`), plus every
// method of 04 §6.1 and the hydration rules of §6.2, through a real URLSession answered by a
// URLProtocol stub. The wire details underneath (encoding, error mapping, deadlines) are pinned
// by InventoryNetworkTests; these pin what the repositories make of them.

private struct HTTPRepositoriesFixture {
    let server: StubServer
    let repos: HTTPRepositories
    let directory: TemporaryDirectory
    let photos: HouseholdFakePhotos
    let cache: HouseholdPhotoCache

    init(photos: HouseholdFakePhotos = HouseholdFakePhotos(), _ handler: @escaping StubServer.Handler) throws {
        server = StubServer(handler)
        directory = try TemporaryDirectory()
        self.photos = photos
        cache = HouseholdPhotoCache(resolver: PhotoPathResolver(documents: directory.documents, caches: directory.caches))
        repos = HTTPRepositories(session: householdTestSession, client: server.householdClient(), photos: photos, photoCache: cache)
    }

    var lines: [String] { server.requests.map(\.line) }

    func cacheFile(_ name: String) -> URL {
        directory.caches.appending(path: "household-photos/\(name)", directoryHint: .notDirectory)
    }
}

private let origin = householdTestSession.origin
private let spaceJSON = ##"{"id":"s1","name":"Garage","icon":"🧰","color":"#7A9E7E","createdAt":1,"updatedAt":1}"##
private let containerJSON = #"{"id":"c1","spaceId":"s1","name":"Box","visualType":"box","shortCode":"BOX-7K2M","createdAt":5,"updatedAt":6,"itemCount":3,"qrToken":"0123456789abcdef0123456789abcdef"}"#

@Suite("createHttpRepositories")
struct HTTPRepositoriesClientTests {
    @Test("lists spaces from the household API")
    func listsSpacesFromTheHouseholdAPI() async throws {
        // RN's fixture omits fields the server always sends; strict decoding needs the real shape.
        let fixture = try HTTPRepositoriesFixture { request in
            #expect(request.url.contains("/v1/spaces"))
            return .json(200, ##"{"spaces":[{"id":"s1","name":"Garage","icon":"🧰","color":"#7A9E7E","createdAt":1,"updatedAt":1,"containerCount":1,"itemCount":2}]}"##)
        }
        let spaces = try await fixture.repos.spaces.listWithCounts()
        #expect(spaces.first?.name == "Garage")
    }

    @Test("PUTs photo bytes then POSTs the item as JSON, and maps 409 to ConflictError")
    func putsPhotoBytesThenPostsTheItemAsJSONAndMaps409ToConflictError() async throws {
        let photos = HouseholdFakePhotos(["file:///photos/cable.webp": Data([1, 2, 3])])
        let fixture = try HTTPRepositoriesFixture(photos: photos) { request in
            if request.method == "PUT", request.path.hasPrefix("/v1/photos/") {
                #expect(request.header("content-type") == "application/octet-stream")
                #expect(request.body == Data([1, 2, 3]))
                return householdUploadReply(request)
            }
            if request.method == "POST", request.path == "/v1/items" {
                #expect(request.header("content-type") == "application/json")
                let photoId = request.jsonObject["photo"]?.objectValue?["id"]?.stringValue ?? ""
                #expect(photoId.range(of: #"^[0-9a-f-]{36}$"#, options: .regularExpression) != nil)
                return .json(201, householdItemJSON(id: "item-1", photoId: photoId, photoUri: "r2:household/primary/photos/\(photoId).webp"))
            }
            if request.method == "PATCH", request.path == "/v1/items/item-1" {
                return .json(409, #"{"error":"conflict","updatedAt":11}"#)
            }
            return .json(404, "{}")
        }

        let created = try await fixture.repos.items.createWithContext(ItemDraft(
            containerId: "c1", name: "Cable", photo: ItemPhotoInput(uri: "file:///photos/cable.webp")
        ))
        #expect(created.id == "item-1")
        #expect(created.photoId?.range(of: #"^[0-9a-f-]{36}$"#, options: .regularExpression) != nil)
        let lines = fixture.lines
        #expect(lines.count == 2)
        #expect(lines.first?.range(of: #"^PUT https://inventory\.wystudio\.be/v1/photos/[0-9a-f-]+$"#, options: .regularExpression) != nil)
        #expect(lines.last == "POST https://inventory.wystudio.be/v1/items")

        await #expect(throws: ConflictError(updatedAt: 11)) {
            _ = try await fixture.repos.items.update("item-1", UpdateItemInput(name: "HDMI", expectedUpdatedAt: 10))
        }
    }
}

@Suite("HTTPRepositories: spaces and containers (04 §6.1)")
struct HTTPRepositoriesPlacesTests {
    @Test("every request carries the session token to the session's origin")
    func sessionTokenAndOrigin() async throws {
        let fixture = try HTTPRepositoriesFixture { _ in .json(200, #"{"spaces":[]}"#) }
        _ = try await fixture.repos.spaces.listWithCounts()
        let request = try #require(fixture.server.lastRequest)
        #expect(request.line == "GET \(origin)/v1/spaces")
        #expect(request.header("authorization") == "Bearer tok")
    }

    @Test("a space that is gone reads as nil, for a read and an update")
    func spaceGone() async throws {
        let fixture = try HTTPRepositoriesFixture { _ in .json(404, #"{"error":"not_found"}"#) }
        #expect(try await fixture.repos.spaces.getById("s9") == nil)
        #expect(try await fixture.repos.spaces.update("s9", UpdateSpaceInput(name: "x")) == nil)
        #expect(fixture.lines == ["GET \(origin)/v1/spaces/s9", "PATCH \(origin)/v1/spaces/s9"])
    }

    @Test("creating a space sends the input verbatim; an update sends only the given fields")
    func spaceBodies() async throws {
        let fixture = try HTTPRepositoriesFixture { request in
            .json(request.method == "POST" ? 201 : 200, spaceJSON)
        }
        _ = try await fixture.repos.spaces.create(CreateSpaceInput(name: "  Garage ", icon: "🧰", color: "#7A9E7E"))
        _ = try await fixture.repos.spaces.update("s1", UpdateSpaceInput(icon: "🚗"))
        let bodies = fixture.server.requests.compactMap(\.json)
        #expect(bodies.first == .object(["name": .string("  Garage "), "icon": .string("🧰"), "color": .string("#7A9E7E")]))
        #expect(bodies.last == .object(["icon": .string("🚗")]))
    }

    @Test("a space's deletion impact comes from the space list, with no photo or label counts")
    func spaceDeletionImpact() async throws {
        let fixture = try HTTPRepositoriesFixture { request in
            if request.path == "/v1/spaces/s1" { return .json(200, spaceJSON) }
            if request.path == "/v1/spaces" {
                return .json(200, #"{"spaces":[{"id":"s0","name":"Attic","icon":"","color":"","createdAt":1,"updatedAt":1,"containerCount":9,"itemCount":9},{"id":"s1","name":"Garage","icon":"","color":"","createdAt":1,"updatedAt":1,"containerCount":2,"itemCount":5}]}"#)
            }
            return .json(404, "{}")
        }
        let impact = try await fixture.repos.spaces.deletionImpact("s1")
        #expect(impact == SpaceDeletionImpact(containerCount: 2, itemCount: 5, photoCount: 0, qrBindingCount: 0))
    }

    @Test("a gone space's deletion impact is all zeros, without listing the spaces")
    func goneSpaceDeletionImpact() async throws {
        let fixture = try HTTPRepositoriesFixture { _ in .json(404, #"{"error":"not_found"}"#) }
        let impact = try await fixture.repos.spaces.deletionImpact("s9")
        #expect(impact == SpaceDeletionImpact(containerCount: 0, itemCount: 0, photoCount: 0, qrBindingCount: 0))
        #expect(fixture.lines == ["GET \(origin)/v1/spaces/s9"])
    }

    @Test("deletes report the server's orphaned URIs, and nothing deleted on 404")
    func deletes() async throws {
        let fixture = try HTTPRepositoriesFixture { request in
            switch request.path {
            case "/v1/spaces/s1": .json(200, #"{"deleted":true,"orphanedPhotoUris":["r2:a"]}"#)
            case "/v1/containers/c1": .json(200, #"{"deleted":true}"#)
            case "/v1/items/i1": .json(200, #"{"deleted":true,"orphanedPhotoUris":["r2:b","r2:c"]}"#)
            default: .json(404, #"{"error":"not_found"}"#)
            }
        }
        #expect(try await fixture.repos.spaces.delete("s1") == DeletionResult(deleted: true, orphanedPhotoUris: ["r2:a"]))
        #expect(try await fixture.repos.containers.delete("c1") == DeletionResult(deleted: true, orphanedPhotoUris: []))
        #expect(try await fixture.repos.items.delete("i1") == DeletionResult(deleted: true, orphanedPhotoUris: ["r2:b", "r2:c"]))
        #expect(try await fixture.repos.spaces.delete("s9") == .notDeleted)
        #expect(try await fixture.repos.containers.delete("c9") == .notDeleted)
        #expect(try await fixture.repos.items.delete("i9") == .notDeleted)
        #expect(fixture.server.requests.allSatisfy { $0.method == "DELETE" })
    }

    @Test("ids go into paths unencoded; the space filter is percent-encoded")
    func pathEncoding() async throws {
        let fixture = try HTTPRepositoriesFixture { _ in .json(200, #"{"containers":[]}"#) }
        _ = try await fixture.repos.containers.listBySpace("a b/c")
        _ = try await fixture.repos.containers.listAllWithSpace()
        #expect(fixture.lines == ["GET \(origin)/v1/containers?spaceId=a%20b%2Fc", "GET \(origin)/v1/containers"])
    }

    @Test("a container read returns the container; with counts, its item count and label")
    func containerReads() async throws {
        let fixture = try HTTPRepositoriesFixture { _ in .json(200, containerJSON) }
        let container = try #require(try await fixture.repos.containers.getById("c1"))
        #expect(container == Container(id: "c1", spaceId: "s1", name: "Box", visualType: .box, shortCode: "BOX-7K2M", createdAt: 5, updatedAt: 6))
        let counted = try #require(try await fixture.repos.containers.getWithCounts("c1"))
        #expect(counted.itemCount == 3)
        #expect(counted.qrToken == "0123456789abcdef0123456789abcdef")
    }

    @Test("a container's deletion impact: its item count, no photo count, a label only for a non-empty token")
    func containerDeletionImpact() async throws {
        let fixture = try HTTPRepositoriesFixture { request in
            switch request.path {
            case "/v1/containers/c1": .json(200, containerJSON)
            case "/v1/containers/c2": .json(200, #"{"id":"c2","spaceId":"s1","name":null,"visualType":"bin","shortCode":"BIN-0000","createdAt":1,"updatedAt":1,"itemCount":0,"qrToken":""}"#)
            default: .json(404, #"{"error":"not_found"}"#)
            }
        }
        #expect(try await fixture.repos.containers.deletionImpact("c1") == ContainerDeletionImpact(itemCount: 3, photoCount: 0, hasQrBinding: true))
        #expect(try await fixture.repos.containers.deletionImpact("c2") == ContainerDeletionImpact(itemCount: 0, photoCount: 0, hasQrBinding: false))
        #expect(try await fixture.repos.containers.deletionImpact("c9") == ContainerDeletionImpact(itemCount: 0, photoCount: 0, hasQrBinding: false))
    }

    @Test("container bodies: create leaves out a missing name; update clears a name with null")
    func containerBodies() async throws {
        let fixture = try HTTPRepositoriesFixture { request in
            .json(request.method == "POST" ? 201 : 200, #"{"id":"c1","spaceId":"s1","name":null,"visualType":"box","shortCode":"BOX-7K2M","createdAt":5,"updatedAt":6}"#)
        }
        _ = try await fixture.repos.containers.create(CreateContainerInput(spaceId: "s1", visualType: .box))
        _ = try await fixture.repos.containers.update("c1", UpdateContainerInput(name: .clear, spaceId: "s2"))
        _ = try await fixture.repos.containers.update("c1", UpdateContainerInput(visualType: .shelf))
        let bodies = fixture.server.requests.compactMap(\.json)
        #expect(bodies[0] == .object(["spaceId": .string("s1"), "visualType": .string("box")]))
        #expect(bodies[1] == .object(["name": .null, "spaceId": .string("s2")]))
        #expect(bodies[2] == .object(["visualType": .string("shelf")]))
    }
}

@Suite("HTTPRepositories: items (04 §6.1)")
struct HTTPRepositoriesItemsTests {
    @Test("lists read the container, the drop zone and the recent items; limit is encoded")
    func listPaths() async throws {
        let fixture = try HTTPRepositoriesFixture { _ in .json(200, #"{"items":[]}"#) }
        _ = try await fixture.repos.items.listByContainer("drop-zone")
        _ = try await fixture.repos.items.listUnsorted()
        _ = try await fixture.repos.items.listRecent(limit: 7)
        _ = try await fixture.repos.items.listRecent()
        #expect(fixture.lines == [
            "GET \(origin)/v1/items?containerId=drop-zone",
            "GET \(origin)/v1/items?unsorted=1",
            "GET \(origin)/v1/items?recent=1&limit=7",
            "GET \(origin)/v1/items?recent=1&limit=40",
        ])
    }

    @Test("counting the drop zone downloads no thumbnails")
    func countUnsortedSkipsThumbnails() async throws {
        let fixture = try HTTPRepositoriesFixture { request in
            #expect(!request.path.hasPrefix("/v1/photos/"))
            return .json(200, "{\"items\":[\(householdItemJSON(id: "i1", photoId: "p1", photoUri: "r2:p1"))]}")
        }
        #expect(try await fixture.repos.items.countUnsorted() == 1)
        #expect(fixture.server.requests.count == 1)
    }

    @Test("countAll sums the spaces' item counts, so drop-zone items are not counted")
    func countAllExcludesDropZone() async throws {
        let fixture = try HTTPRepositoriesFixture { _ in
            .json(200, #"{"spaces":[{"id":"s1","name":"A","icon":"","color":"","createdAt":1,"updatedAt":1,"containerCount":1,"itemCount":2},{"id":"s2","name":"B","icon":"","color":"","createdAt":1,"updatedAt":1,"containerCount":0,"itemCount":3}]}"#)
        }
        #expect(try await fixture.repos.items.countAll() == 5)
        #expect(fixture.lines == ["GET \(origin)/v1/spaces"])
    }

    @Test("an item that is gone reads as nil, and an update of one returns nil")
    func itemGone() async throws {
        let fixture = try HTTPRepositoriesFixture { _ in .json(404, #"{"error":"not_found"}"#) }
        #expect(try await fixture.repos.items.getById("i9") == nil)
        #expect(try await fixture.repos.items.update("i9", UpdateItemInput(quantity: 2)) == nil)
        #expect(try await fixture.repos.items.getPhotos("i9") == [])
    }

    @Test("an update sends the item fields and the lock, never the photo")
    func updateBody() async throws {
        let fixture = try HTTPRepositoriesFixture { _ in
            .json(200, #"{"id":"i1","containerId":"c2","name":"Drill","category":null,"quantity":0,"notes":"n","createdAt":1,"updatedAt":2}"#)
        }
        let item = try await fixture.repos.items.update("i1", UpdateItemInput(
            containerId: "c2", category: .clear, quantity: 0, notes: .set("n"), tags: ["a"],
            photo: .set(ItemPhotoInput(uri: "file:///p.webp")), expectedUpdatedAt: 1
        ))
        #expect(item?.updatedAt == 2)
        let request = try #require(fixture.server.lastRequest)
        #expect(request.line == "PATCH \(origin)/v1/items/i1")
        #expect(request.json == .object([
            "containerId": .string("c2"), "category": .null, "quantity": .number(0), "notes": .string("n"),
            "tags": .array([.string("a")]), "updatedAt": .number(1),
        ]))
    }

    @Test("a create without a photo is one POST with the draft's fields, the photo id never sent")
    func createWithoutPhoto() async throws {
        let fixture = try HTTPRepositoriesFixture { _ in .json(201, householdItemJSON(id: "i1")) }
        let item = try await fixture.repos.items.create(ItemDraft(containerId: "drop-zone", quantity: 2, tags: ["x"]))
        #expect(item.id == "i1")
        #expect(fixture.lines == ["POST \(origin)/v1/items"])
        #expect(fixture.server.lastRequest?.json == .object(["containerId": .string("drop-zone"), "quantity": .number(2), "tags": .array([.string("x")])]))
    }

    @Test("a create whose photo file is gone fails as photo_missing before any request")
    func createWithMissingPhoto() async throws {
        let fixture = try HTTPRepositoriesFixture { _ in .json(201, householdItemJSON(id: "i1")) }
        await #expect(throws: HouseholdHttpError(status: 0, code: "photo_missing")) {
            _ = try await fixture.repos.items.create(ItemDraft(containerId: "c1", name: "x", photo: ItemPhotoInput(uri: "file:///gone.webp")))
        }
        #expect(fixture.server.requests.isEmpty)
    }

    @Test("the create answer is returned raw, with the server's r2 URIs, and the capture is copied into the cache")
    func createRemembersTheCapture() async throws {
        let directory = try TemporaryDirectory()
        let full = try directory.write(Data([1, 2, 3]), to: "Documents/item-photos/cap.webp")
        let thumb = try directory.write(Data([4]), to: "Documents/item-photos/cap-thumb.webp")
        let photos = HouseholdFakePhotos([full.absoluteString: Data([1, 2, 3])])
        let server = StubServer { request in
            if request.method == "PUT" { return householdUploadReply(request) }
            let photoId = request.jsonObject["photo"]?.objectValue?["id"]?.stringValue ?? ""
            return .json(201, householdItemJSON(
                id: "i1", photoId: photoId,
                photoUri: "r2:household/primary/photos/\(photoId).webp",
                photoThumbUri: "r2:household/primary/photos/\(photoId)-thumb.webp"
            ))
        }
        let cache = HouseholdPhotoCache(resolver: PhotoPathResolver(documents: directory.documents, caches: directory.caches))
        let repos = HTTPRepositories(session: householdTestSession, client: server.householdClient(), photos: photos, photoCache: cache)

        let created = try await repos.items.createWithContext(ItemDraft(
            containerId: "c1", name: "Cable",
            photo: ItemPhotoInput(id: "local-id", uri: full.absoluteString, thumbUri: thumb.absoluteString, width: 9, height: 9, byteSize: 9)
        ))
        let photoId = try #require(created.photoId)
        #expect(created.photoUri == "r2:household/primary/photos/\(photoId).webp")
        // The draft's own id and size are never sent; the upload answer's are.
        let post = try #require(server.requests.last)
        #expect(post.jsonObject["photo"] == .object([
            "id": .string(photoId), "uri": .string("r2:household/primary/photos/\(photoId).webp"),
            "thumbUri": .string("r2:household/primary/photos/\(photoId)-thumb.webp"),
            "width": .number(10), "height": .number(10), "byteSize": .number(3),
        ]))
        let cached = directory.caches.appending(path: "household-photos", directoryHint: .isDirectory)
        #expect(try Data(contentsOf: cached.appending(path: "\(photoId).webp")) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: cached.appending(path: "\(photoId)-thumb.webp")) == Data([4]))
    }

    @Test("lists fetch only thumbnails and keep the server's full URI")
    func listHydratesThumbnails() async throws {
        let fixture = try HTTPRepositoriesFixture { request in
            switch request.path {
            case "/v1/photos/p1?thumb=1": return .bytes(200, Data([7]))
            case "/v1/photos/p2?thumb=1": return .json(404, #"{"error":"not_found"}"#)
            default:
                let items = [
                    householdItemJSON(id: "i1", photoId: "p1", photoUri: "r2:p1", photoThumbUri: "r2:p1-thumb"),
                    householdItemJSON(id: "i2", photoId: "p2", photoUri: "r2:p2", photoThumbUri: "r2:p2-thumb"),
                    householdItemJSON(id: "i3"),
                    householdItemJSON(id: "i4", photoId: "p4", photoUri: "r2:p4", photoThumbUri: "file:///already/p4-thumb.webp"),
                ]
                return .json(200, "{\"items\":[\(items.joined(separator: ","))]}")
            }
        }
        let items = try await fixture.repos.items.listByContainer("c1")
        #expect(items.map(\.id) == ["i1", "i2", "i3", "i4"])
        #expect(items[0].photoThumbUri == fixture.cacheFile("p1-thumb.webp").absoluteString)
        #expect(items[0].photoUri == "r2:p1")
        // A thumbnail that cannot be fetched keeps the server's value.
        #expect(items[1].photoThumbUri == "r2:p2-thumb")
        #expect(items[2].photoThumbUri == nil)
        // A thumbnail that is already a local file is not fetched again.
        #expect(items[3].photoThumbUri == "file:///already/p4-thumb.webp")
        #expect(Set(fixture.server.requests(to: "/v1/photos/").map(\.path)) == ["/v1/photos/p1?thumb=1", "/v1/photos/p2?thumb=1"])
    }

    @Test("the item screen fetches the full photo and its thumbnail; a local full URI is left alone")
    func detailHydratesBoth() async throws {
        let fixture = try HTTPRepositoriesFixture { request in
            switch request.path {
            case "/v1/items/i1": .json(200, householdItemJSON(id: "i1", photoId: "p1", photoUri: "r2:p1", photoThumbUri: "r2:p1-thumb"))
            case "/v1/items/i2": .json(200, householdItemJSON(id: "i2", photoId: "p2", photoUri: "file:///x/p2.webp", photoThumbUri: "r2:p2-thumb"))
            case "/v1/photos/p1": .bytes(200, Data([1]))
            case "/v1/photos/p1?thumb=1": .bytes(200, Data([2]))
            default: .json(404, "{}")
            }
        }
        let item = try #require(try await fixture.repos.items.getById("i1"))
        #expect(item.photoUri == fixture.cacheFile("p1.webp").absoluteString)
        #expect(item.photoThumbUri == fixture.cacheFile("p1-thumb.webp").absoluteString)

        let local = try #require(try await fixture.repos.items.getById("i2"))
        #expect(local.photoUri == "file:///x/p2.webp")
        #expect(local.photoThumbUri == "r2:p2-thumb")
        #expect(fixture.server.requests(to: "/v1/photos/p2").isEmpty)
    }

    @Test("an item's photos: one with the hydrated URIs and the item's createdAt, or none")
    func getPhotos() async throws {
        let fixture = try HTTPRepositoriesFixture { request in
            switch request.path {
            case "/v1/items/i1": .json(200, householdItemJSON(id: "i1", photoId: "p1", photoUri: "r2:p1", photoThumbUri: "r2:p1-thumb"))
            case "/v1/items/i2": .json(200, householdItemJSON(id: "i2"))
            case "/v1/items/i3": .json(200, householdItemJSON(id: "i3", photoId: "p3"))
            case "/v1/photos/p1": .bytes(200, Data([1]))
            default: .json(404, #"{"error":"not_found"}"#)
            }
        }
        let photos = try await fixture.repos.items.getPhotos("i1")
        #expect(photos == [ItemPhoto(
            id: "p1", itemId: "i1", uri: fixture.cacheFile("p1.webp").absoluteString,
            thumbUri: "r2:p1-thumb", width: nil, height: nil, byteSize: nil, createdAt: 10
        )])
        #expect(try await fixture.repos.items.getPhotos("i2") == [])
        #expect(try await fixture.repos.items.getPhotos("i3") == [])
    }
}

@Suite("HTTPRepositories: labels and search (04 §6.1)")
struct HTTPRepositoriesLabelsTests {
    @Test("a container's label uses the container's id and timestamps (RN quirk)")
    func getByContainer() async throws {
        let fixture = try HTTPRepositoriesFixture { request in
            switch request.path {
            case "/v1/containers/c1": .json(200, containerJSON)
            case "/v1/containers/c2": .json(200, #"{"id":"c2","spaceId":"s1","name":null,"visualType":"box","shortCode":"BOX-0000","createdAt":1,"updatedAt":1,"itemCount":0,"qrToken":null}"#)
            default: .json(404, #"{"error":"not_found"}"#)
            }
        }
        let binding = try await fixture.repos.qr.getByContainer("c1")
        #expect(binding == QrBinding(id: "c1", token: "0123456789abcdef0123456789abcdef", containerId: "c1", createdAt: 5, updatedAt: 6))
        #expect(try await fixture.repos.qr.getByContainer("c2") == nil)
        #expect(try await fixture.repos.qr.getByContainer("c9") == nil)
    }

    @Test("a token lookup is not supported: nil without a request")
    func getByToken() async throws {
        let fixture = try HTTPRepositoriesFixture { _ in .json(500, "{}") }
        #expect(try await fixture.repos.qr.getByToken("0123456789abcdef0123456789abcdef") == nil)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test("binding, labelling, scanning and unbinding call their endpoints")
    func labelWrites() async throws {
        let binding = #"{"id":"q1","token":"0123456789abcdef0123456789abcdef","containerId":"c1","createdAt":1,"updatedAt":1}"#
        let fixture = try HTTPRepositoriesFixture { request in
            switch (request.method, request.path) {
            case ("POST", "/v1/qr/bind"): .json(200, binding)
            case ("POST", "/v1/containers/c1/qr"): .json(201, binding)
            case ("POST", "/v1/qr/scan"): .json(200, #"{"kind":"unknown","token":"0123456789abcdef0123456789abcdef"}"#)
            case ("DELETE", "/v1/containers/c1/qr"): .status(204)
            default: .json(404, #"{"error":"not_found"}"#)
            }
        }
        #expect(try await fixture.repos.qr.bind(token: "0123456789abcdef0123456789abcdef", containerId: "c1").id == "q1")
        #expect(try await fixture.repos.qr.createAndBind("c1").id == "q1")
        #expect(try await fixture.repos.qr.resolveScan("raw text") == .unknown(token: "0123456789abcdef0123456789abcdef"))
        #expect(try await fixture.repos.qr.unbind("c1"))
        #expect(try await fixture.repos.qr.unbind("c9") == false)
        #expect(fixture.server.requests[0].json == .object(["token": .string("0123456789abcdef0123456789abcdef"), "containerId": .string("c1")]))
        #expect(fixture.server.requests[2].json == .object(["raw": .string("raw text")]))
    }

    @Test("search makes each item's thumbnail local; location searches are empty without a request")
    func search() async throws {
        let fixture = try HTTPRepositoriesFixture { request in
            if request.path == "/v1/photos/p1?thumb=1" { return .bytes(200, Data([1])) }
            let item = householdItemJSON(id: "i1", photoId: "p1", photoUri: "r2:p1", photoThumbUri: "r2:p1-thumb")
            let hit = String(item.dropLast()) + #","matchKind":"direct"}"#
            return .json(200, #"{"terms":["cable"],"locations":[{"kind":"space","id":"s1","title":"Garage","subtitle":"Space","spaceId":"s1","itemCount":1}],"items":["# + hit + "]}")
        }
        let results = try await fixture.repos.search.search("Cable box")
        #expect(results.terms == ["cable"])
        #expect(results.locations.map(\.id) == ["s1"])
        #expect(results.items.first?.photoThumbUri == fixture.cacheFile("p1-thumb.webp").absoluteString)
        #expect(results.items.first?.matchKind == .direct)
        #expect(fixture.server.requests.first?.path == "/v1/search?q=Cable%20box")
        #expect(try await fixture.repos.search.searchSpaces(["garage"]) == [])
        #expect(try await fixture.repos.search.searchContainers(["box"]) == [])
        #expect(fixture.server.requests.count == 2)
    }
}
