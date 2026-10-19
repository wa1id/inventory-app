import Foundation
import InventoryCore
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryNetwork

// RN: src/services/household/__tests__/client.test.ts and devices.test.ts, through
// a real URLSession answered by a URLProtocol stub, plus the request rules of 04 §3.

private let origin = "https://inventory.wystudio.be"

private func client(_ server: StubServer, origin: String = origin, token: String? = "tok", hub: ReachabilityHub? = nil, telemetry: RecordingTelemetry = RecordingTelemetry(), makeId: (@Sendable () -> String)? = nil) -> HouseholdClient {
    HouseholdClient(
        origin: origin, token: token, transport: server.transport, reachability: hub,
        telemetry: telemetry.telemetry, makeId: makeId ?? { newId() }
    )
}

private func httpError(_ work: () async throws -> Void) async -> HouseholdHttpError? {
    do {
        try await work()
        return nil
    } catch let error as HouseholdHttpError {
        return error
    } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

private let space = ##"{"id":"s1","name":"Garage","icon":"🧰","color":"#7A9E7E","createdAt":1,"updatedAt":1,"containerCount":1,"itemCount":2}"##
private func itemWithContext(id: String, photoId: String?) -> String {
    let photo = photoId.map { #""photoId":"\#($0)","photoUri":"r2:household/primary/photos/\#($0).webp","photoThumbUri":"r2:household/primary/photos/\#($0)-thumb.webp""# }
        ?? #""photoId":null,"photoUri":null,"photoThumbUri":null"#
    return ##"{"id":"\##(id)","containerId":"c1","name":"Cable","category":null,"quantity":1,"notes":null,"createdAt":10,"updatedAt":10,\##(photo),"tags":[],"spaceId":"s1","spaceName":"Garage","spaceIcon":"🧰","spaceColor":"#7A9E7E","containerName":"Box","containerShortCode":"BOX-7K2M"}"##
}

@Suite("pairWithHousehold")
struct PairWithHouseholdTests {
    @Test("stores the token and origin from a successful pair")
    func storesTheTokenAndOriginFromASuccessfulPair() async throws {
        let server = StubServer(reply: .json(200, #"{"token":"abc","deviceId":"dev-1","origin":"https://inventory.wystudio.be","householdName":"Home","contractVersion":1}"#))
        let pairing = try await client(server, token: nil).pair(bootstrapSecret: "MMWKY-M2H78", deviceName: "Pixel")
        #expect(pairing.token == "abc")
        #expect(pairing.deviceId == "dev-1")
        #expect(pairing.origin == "https://inventory.wystudio.be")
        #expect(!server.requests.isEmpty)
    }

    @Test("maps 401 to HouseholdHttpError")
    func maps401ToHouseholdHttpError() async {
        let server = StubServer(reply: .json(401, #"{"error":"unauthorized"}"#))
        let error = await httpError { _ = try await client(server, token: nil).pair(bootstrapSecret: "nope", deviceName: "Pixel") }
        #expect(error == HouseholdHttpError(status: 401, code: "unauthorized"))
    }

    // MARK: Native additions (04 §2.3)

    @Test("sends the code and name untouched, without a token, to the origin without trailing slashes")
    func sendsThePairRequest() async throws {
        let server = StubServer(reply: .json(200, #"{"token":"abc","deviceId":"dev-1","origin":"https://box.example///"}"#))
        let pairing = try await client(server, origin: "https://inventory.example//", token: "stale").pair(bootstrapSecret: "MMWKY-M2H78", deviceName: "  Pixel 8 ")
        let request = try #require(server.lastRequest)
        #expect(request.line == "POST https://inventory.example/v1/pair")
        #expect(request.header("authorization") == nil)
        #expect(request.header("content-type") == "application/json")
        #expect(request.header("accept") == "application/json")
        #expect(request.json == .object(["bootstrapSecret": .string("MMWKY-M2H78"), "deviceName": .string("  Pixel 8 ")]))
        #expect(pairing == HouseholdPairing(origin: "https://box.example", token: "abc", deviceId: "dev-1", deviceName: "Pixel 8", householdName: "Home"))
    }

    @Test("an answer without string token, deviceId and origin is (500, invalid_response)", arguments: [
        #"{"deviceId":"d","origin":"o"}"#, #"{"token":1,"deviceId":"d","origin":"o"}"#, #"{"token":"t","origin":"o"}"#,
        #"{"token":"t","deviceId":"d"}"#, "[]", "",
    ])
    func rejectsIncompletePairAnswers(body: String) async {
        let server = StubServer(reply: .json(200, body))
        let error = await httpError { _ = try await client(server, token: nil).pair(bootstrapSecret: "x", deviceName: "y") }
        #expect(error == HouseholdHttpError(status: 500, code: "invalid_response"))
    }

    @Test("keeps a string household name and falls back to Home otherwise")
    func householdName() async throws {
        let named = StubServer(reply: .json(200, #"{"token":"t","deviceId":"d","origin":"o","householdName":"Cabin"}"#))
        #expect(try await client(named).pair(bootstrapSecret: "x", deviceName: "y").householdName == "Cabin")
        let odd = StubServer(reply: .json(200, #"{"token":"t","deviceId":"d","origin":"o","householdName":7}"#))
        #expect(try await client(odd).pair(bootstrapSecret: "x", deviceName: "y").householdName == "Home")
    }

    @Test("never prints the token")
    func neverPrintsTheToken() {
        let pairing = HouseholdPairing(origin: "o", token: "secret-token", deviceId: "d", deviceName: "n", householdName: "h")
        var dumped = ""
        dump(pairing, to: &dumped)
        #expect(!String(describing: pairing).contains("secret-token"))
        #expect(!dumped.contains("secret-token"))
        let household = HouseholdClient(origin: "o", token: "secret-token")
        dumped = ""
        dump(household, to: &dumped)
        #expect(!String(describing: household).contains("secret-token"))
        #expect(!dumped.contains("secret-token"))
    }
}

@Suite("createHttpRepositories (the typed endpoints underneath)")
struct HouseholdEndpointTests {
    @Test("lists spaces from the household API")
    func listsSpacesFromTheHouseholdAPI() async throws {
        // RN's fixture omits fields the server always sends; strict decoding needs the real shape.
        let server = StubServer { request in
            #expect(request.url.contains("/v1/spaces"))
            return .json(200, #"{"spaces":[\#(space)]}"#)
        }
        let spaces = try await client(server).listSpaces()
        #expect(spaces.first?.name == "Garage")
    }

    @Test("PUTs photo bytes then POSTs the item as JSON, and maps 409 to ConflictError")
    func putsPhotoBytesThenPostsTheItemAsJSONAndMaps409ToConflictError() async throws {
        let server = StubServer { request in
            if request.method == "PUT", request.url.contains("/v1/photos/") {
                #expect(request.header("content-type") == "application/octet-stream")
                #expect(request.body == Data([1, 2, 3]))
                let photoId = request.url.components(separatedBy: "/v1/photos/").last ?? "p1"
                return .json(201, #"{"id":"\#(photoId)","uri":"r2:household/primary/photos/\#(photoId).webp","thumbUri":"r2:household/primary/photos/\#(photoId)-thumb.webp","width":10,"height":10,"byteSize":3}"#)
            }
            if request.method == "POST", request.url.hasSuffix("/v1/items") {
                #expect(request.header("content-type") == "application/json")
                let photoId = request.jsonObject["photo"]?.objectValue?["id"]?.stringValue ?? ""
                #expect(photoId.range(of: #"^[0-9a-f-]{36}$"#, options: .regularExpression) != nil)
                return .json(201, itemWithContext(id: "item-1", photoId: photoId))
            }
            if request.method == "PATCH", request.url.hasSuffix("/v1/items/item-1") {
                return .json(409, #"{"error":"conflict","updatedAt":11}"#)
            }
            return .json(404, "{}")
        }
        let household = client(server)

        let photo = try await household.uploadPhoto(Data([1, 2, 3]))
        let created = try await household.createItem(.init(containerId: "c1", name: "Cable", photo: photo.reference))
        #expect(created.id == "item-1")
        #expect(created.photoId?.range(of: #"^[0-9a-f-]{36}$"#, options: .regularExpression) != nil)
        let lines = server.requests.map(\.line)
        #expect(lines.count == 2)
        #expect(lines.first?.range(of: #"^PUT https://inventory\.wystudio\.be/v1/photos/[0-9a-f-]+$"#, options: .regularExpression) != nil)
        #expect(lines.last == "POST https://inventory.wystudio.be/v1/items")

        await #expect(throws: ConflictError(updatedAt: 11)) {
            _ = try await household.updateItem(id: "item-1", .init(name: "HDMI", expectedUpdatedAt: 10))
        }
    }

    // MARK: Native additions (04 §3, §16.1)

    @Test("the photo reference carries only the well-typed fields of the upload answer")
    func photoReferenceIsLenient() async throws {
        let server = StubServer(reply: .json(201, #"{"id":"p","uri":"r2:x","thumbUri":5,"width":"10","height":10,"byteSize":null}"#))
        let photo = try await client(server).uploadPhoto(Data([1]))
        #expect(photo == HouseholdUploadedPhoto(id: "p", uri: "r2:x", thumbUri: nil, width: nil, height: 10, byteSize: nil))
        let request = try #require(server.lastRequest)
        #expect(request.path.range(of: #"^/v1/photos/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil)
    }

    @Test("an upload answer without string id and uri is (500, invalid_response); a server error passes through")
    func uploadFailures() async {
        let incomplete = StubServer(reply: .json(201, #"{"id":"p"}"#))
        #expect(await httpError { _ = try await client(incomplete).uploadPhoto(Data([1])) } == HouseholdHttpError(status: 500, code: "invalid_response"))
        let unconfigured = StubServer(reply: .json(503, #"{"error":"photos_not_configured"}"#))
        #expect(await httpError { _ = try await client(unconfigured).uploadPhoto(Data([1])) } == HouseholdHttpError(status: 503, code: "photos_not_configured"))
    }

    @Test("PATCH bodies tell a missing key from an explicit null (04 §3.7)")
    func triStatePatches() async throws {
        let server = StubServer(reply: .json(200, #"{"id":"i","containerId":"c","name":"n","category":null,"quantity":1,"notes":null,"createdAt":1,"updatedAt":2}"#))
        let household = client(server)
        _ = try await household.updateItem(id: "i", .init(category: .clear, notes: .unchanged))
        #expect(server.lastRequest?.json == .object(["category": .null]))
        _ = try await household.updateItem(id: "i", .init(name: "Drill", category: .set("Tools"), notes: .clear, expectedUpdatedAt: 7))
        #expect(server.lastRequest?.json == .object(["name": .string("Drill"), "category": .string("Tools"), "notes": .null, "updatedAt": .number(7)]))
        _ = try await household.updateItem(id: "i", .init())
        #expect(server.lastRequest?.json == .object([:]))

        let containers = StubServer(reply: .json(200, #"{"id":"c","spaceId":"s","name":null,"visualType":"box","shortCode":"BOX-1","createdAt":1,"updatedAt":1}"#))
        _ = try await client(containers).updateContainer(id: "c", .init(name: .clear))
        #expect(containers.lastRequest?.json == .object(["name": .null]))
        _ = try await client(containers).updateContainer(id: "c", .init(spaceId: "s2"))
        #expect(containers.lastRequest?.json == .object(["spaceId": .string("s2")]))
    }

    @Test("create bodies leave out what was not given")
    func createBodies() async throws {
        let server = StubServer(reply: .json(201, itemWithContext(id: "i", photoId: nil)))
        _ = try await client(server).createItem(.init(containerId: "drop-zone"))
        #expect(server.lastRequest?.json == .object(["containerId": .string("drop-zone")]))
        let spaces = StubServer(reply: .json(200, #"{"id":"s","name":"A","icon":"x","color":"y","createdAt":1,"updatedAt":1}"#))
        _ = try await client(spaces).updateSpace(id: "s", .init(color: "#000000"))
        #expect(spaces.lastRequest?.json == .object(["color": .string("#000000")]))
    }

    @Test("ids go into paths as they are; query values and device and photo ids are percent-encoded")
    func pathEncoding() async throws {
        let server = StubServer(reply: .json(200, "{}"))
        let household = client(server)
        _ = try await household.listContainers(spaceId: "a b/c")
        _ = try await household.listItems(containerId: "drop-zone")
        _ = try await household.listRecentItems(limit: 12)
        _ = try await household.search("drill & bits/€")
        _ = try await household.photo(id: "a/b", thumbnail: true)
        _ = try await household.unbindLabel(containerId: "c-1")
        #expect(server.requests.map(\.path) == [
            "/v1/containers?spaceId=a%20b%2Fc",
            "/v1/items?containerId=drop-zone",
            "/v1/items?recent=1&limit=12",
            "/v1/search?q=drill%20%26%20bits%2F%E2%82%AC",
            "/v1/photos/a%2Fb?thumb=1",
            "/v1/containers/c-1/qr",
        ])
    }

    @Test("missing list keys read as empty; a malformed element is (status, invalid_response)")
    func lenientLists() async throws {
        let empty = StubServer(reply: .json(200, "{}"))
        let household = client(empty)
        #expect(try await household.listSpaces().isEmpty)
        #expect(try await household.listAllContainers().isEmpty)
        #expect(try await household.listUnsortedItems().isEmpty)
        let nulls = StubServer(reply: .json(200, #"{"spaces":null,"items":null}"#))
        #expect(try await client(nulls).listSpaces().isEmpty)
        let array = StubServer(reply: .json(200, "[]"))
        #expect(try await client(array).listSpaces().isEmpty)

        let broken = StubServer(reply: .json(200, #"{"spaces":[{"id":"s1","name":"Garage"}]}"#))
        #expect(await httpError { _ = try await client(broken).listSpaces() } == HouseholdHttpError(status: 200, code: "invalid_response"))
        let notAList = StubServer(reply: .json(200, #"{"items":"x"}"#))
        #expect(await httpError { _ = try await client(notAList).listUnsortedItems() } == HouseholdHttpError(status: 200, code: "invalid_response"))
    }

    @Test("typed answers decode what JSON.parse saw: a lone surrogate as U+FFFD, the last of duplicate keys")
    func decodesWhatJSONParseSaw() async throws {
        // The server cuts names with slice(), which can leave half an emoji; JSONDecoder alone refuses that body.
        let cut = ##"{"spaces":[{"id":"s1","name":"Tools \ud83d","icon":"🧰","color":"#7A9E7E","createdAt":1,"updatedAt":1,"containerCount":0,"itemCount":0}]}"##
        let spaces = try await client(StubServer(reply: .json(200, cut))).listSpaces()
        #expect(spaces.map(\.name) == ["Tools \u{FFFD}"])
        let twice = ##"{"id":"s1","name":"Old","name":"New","icon":"x","color":"y","createdAt":1,"updatedAt":2}"##
        let space = try await client(StubServer(reply: .json(200, twice))).space(id: "s1")
        #expect(space?.name == "New")
    }

    @Test("search keeps items only when they are an array")
    func searchFallbacks() async throws {
        let server = StubServer(reply: .json(200, #"{"terms":["x"],"items":"nope"}"#))
        let results = try await client(server).search("x")
        #expect(results == SearchResults(terms: ["x"], locations: [], items: []))
    }

    @Test("a 404 reads as gone where RN ignored it, including Hono's plain-text 404")
    func ignoring404() async throws {
        let json404 = StubServer(reply: .json(404, #"{"error":"not_found"}"#))
        #expect(try await client(json404).item(id: "x") == nil)
        #expect(try await client(json404).deleteItem(id: "x") == .alreadyGone)
        #expect(try await client(json404).unbindLabel(containerId: "c") == false)
        let text404 = StubServer(reply: .text(404, "404 Not Found"))
        #expect(try await client(text404).container(id: "x") == nil)
        #expect(await httpError { _ = try await client(text404).listSpaces() } == HouseholdHttpError(status: 404, code: "invalid_json"))
    }

    @Test("a delete answer without orphaned URIs still reports deleted")
    func deleteWithoutURIs() async throws {
        let server = StubServer(reply: .json(200, "{}"))
        #expect(try await client(server).deleteSpace(id: "s") == HouseholdDeleteResult(deleted: true, orphanedPhotoUris: []))
    }

    @Test("photo downloads return nil for any non-2xx; import photo PUTs report false")
    func photoStatuses() async throws {
        let missing = StubServer(reply: .json(503, #"{"error":"photos_not_configured"}"#))
        #expect(try await client(missing).photo(id: "p", thumbnail: false) == nil)
        #expect(try await client(missing).importPhoto(id: "p", bytes: Data([1])) == false)
        let stored = StubServer(reply: .bytes(200, Data([7, 7]), headers: ["Content-Type": "image/webp"]))
        #expect(try await client(stored).photo(id: "p", thumbnail: false) == Data([7, 7]))
    }

    @Test("the import posts the dump with a 60 s budget and reads the counts it gets back")
    func importSummary() async throws {
        let server = StubServer(reply: .json(200, #"{"ok":true,"spaces":1,"containers":"2","items":3}"#))
        let summary = try await client(server).importDump(HouseholdDump())
        #expect(summary == HouseholdImportSummary(spaces: 1, containers: nil, items: 3, photos: nil))
        #expect(server.lastRequest?.json == .object([
            "spaces": .array([]), "containers": .array([]), "items": .array([]), "tags": .array([]),
            "itemTags": .array([]), "qrBindings": .array([]), "photos": .array([]),
        ]))
    }

    @Test("the dump writes NULL columns as explicit nulls, as JSON.stringify does, never as missing keys")
    func dumpNulls() async throws {
        let server = StubServer(reply: .json(200, #"{"ok":true}"#))
        let dump = HouseholdDump(
            containers: [.init(id: "c", spaceId: "s", name: nil, visualType: .box, shortCode: "BOX-1", kind: .normal, createdAt: 1, updatedAt: 2)],
            items: [.init(id: "i", containerId: "c", name: "", category: nil, quantity: 0, notes: nil, searchText: "", createdAt: 3, updatedAt: 4)],
            photos: [.init(id: "p", itemId: "i", width: nil, height: nil, byteSize: nil, createdAt: 5)]
        )
        _ = try await client(server).importDump(dump)
        let body = try #require(server.lastRequest).jsonObject
        #expect(body["containers"] == .array([.object([
            "id": .string("c"), "spaceId": .string("s"), "name": .null, "visualType": .string("box"),
            "shortCode": .string("BOX-1"), "kind": .string("normal"), "createdAt": .number(1), "updatedAt": .number(2),
        ])]))
        #expect(body["items"] == .array([.object([
            "id": .string("i"), "containerId": .string("c"), "name": .string(""), "category": .null, "quantity": .number(0),
            "notes": .null, "searchText": .string(""), "createdAt": .number(3), "updatedAt": .number(4),
        ])]))
        #expect(body["photos"] == .array([.object([
            "id": .string("p"), "itemId": .string("i"), "width": .null, "height": .null, "byteSize": .null, "createdAt": .number(5),
        ])]))
    }
}

@Suite("listDevices / revokeDevice")
struct HouseholdDevicesTests {
    private static let devicesOrigin = "https://inventory.example"

    @Test("reads the household’s phones with the session token")
    func readsTheHouseholdsPhonesWithTheSessionToken() async throws {
        let server = StubServer(reply: .json(200, #"{"devices":[{"id":"a","name":"Kitchen iPhone","createdAt":1,"lastSeenAt":5},{"id":"b","name":"Anna’s iPhone","createdAt":2,"lastSeenAt":null}]}"#))
        let devices = try await client(server, origin: Self.devicesOrigin, token: "secret-token").listDevices()
        #expect(devices == [
            HouseholdDevice(id: "a", name: "Kitchen iPhone", createdAt: 1, lastSeenAt: 5),
            HouseholdDevice(id: "b", name: "Anna’s iPhone", createdAt: 2, lastSeenAt: nil),
        ])
        let request = try #require(server.lastRequest)
        #expect(request.url == "https://inventory.example/v1/devices")
        #expect(request.method == "GET")
        #expect(request.header("authorization") == "Bearer secret-token")
    }

    @Test("skips entries it cannot read instead of failing the list")
    func skipsEntriesItCannotReadInsteadOfFailingTheList() async throws {
        let server = StubServer(reply: .json(200, #"{"devices":[{"id":"a","name":"Kitchen iPhone","createdAt":1,"lastSeenAt":5},{"id":7},null]}"#))
        let devices = try await client(server, origin: Self.devicesOrigin).listDevices()
        #expect(devices.map(\.id) == ["a"])
    }

    @Test("rejects an answer without a list")
    func rejectsAnAnswerWithoutAList() async {
        let server = StubServer(reply: .json(200, #"{"nope":true}"#))
        let error = await httpError { _ = try await client(server, origin: Self.devicesOrigin).listDevices() }
        #expect(error == HouseholdHttpError(status: 500, code: "invalid_response"))
    }

    @Test("deletes the phone by id")
    func deletesThePhoneByID() async throws {
        let server = StubServer(reply: .status(204))
        try await client(server, origin: Self.devicesOrigin).revokeDevice(id: "a/b")
        let request = try #require(server.lastRequest)
        #expect(request.url == "https://inventory.example/v1/devices/a%2Fb")
        #expect(request.method == "DELETE")
    }

    @Test("treats a phone that is already gone as removed")
    func treatsAPhoneThatIsAlreadyGoneAsRemoved() async throws {
        let server = StubServer(reply: .json(404, #"{"error":"not_found"}"#))
        try await client(server, origin: Self.devicesOrigin).revokeDevice(id: "a")
    }

    @Test("passes other failures on")
    func passesOtherFailuresOn() async {
        let server = StubServer(reply: .json(500, #"{"error":"boom"}"#))
        let error = await httpError { try await client(server, origin: Self.devicesOrigin).revokeDevice(id: "a") }
        #expect(error?.status == 500)
    }
}

@Suite("householdFetch / householdRequest rules")
struct HouseholdRequestRuleTests {
    @Test("every request asks for JSON and carries the bearer token, never the app key")
    func commonHeaders() async throws {
        let server = StubServer(reply: .json(200, #"{"spaces":[]}"#))
        _ = try await client(server, token: "device-token").listSpaces()
        let request = try #require(server.lastRequest)
        #expect(request.header("accept") == "application/json")
        #expect(request.header("authorization") == "Bearer device-token")
        #expect(request.header("content-type") == nil)
        #expect(request.header("x-inventory-key") == nil)
    }

    @Test("an empty token sends no Authorization header")
    func emptyToken() async throws {
        let server = StubServer(reply: .json(200, "{}"))
        _ = try await client(server, token: "").listSpaces()
        #expect(server.lastRequest?.header("authorization") == nil)
    }

    @Test("the health ping is unauthenticated with a 5 s default")
    func healthPing() async throws {
        let server = StubServer(reply: .json(200, #"{"ok":true,"contractVersion":1}"#))
        #expect(try await client(server).health() == HouseholdHealth(ok: true, contractVersion: 1))
        #expect(server.lastRequest?.header("authorization") == nil)
        #expect(HouseholdClient.healthTimeout == .seconds(5))
        #expect(HouseholdClient.defaultTimeout == .seconds(20))
        #expect(HouseholdClient.uploadTimeout == .seconds(60))
    }

    @Test("the deadline is (0, timeout) and reports offline")
    func deadline() async throws {
        let hub = ReachabilityHub()
        let updates = hub.updates()
        let server = StubServer(reply: .json(200, "{}", delay: .seconds(10)))
        let started = ContinuousClock.now
        let error = await httpError {
            _ = try await client(server, hub: hub).request(HouseholdRequest(path: "/v1/spaces", timeout: .milliseconds(100)), as: IgnoredBody.self)
        }
        #expect(error == HouseholdHttpError(status: 0, code: "timeout"))
        #expect(ContinuousClock.now - started < .seconds(5))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .offline)
    }

    @Test("the deadline covers the response body, not just the headers (D-7)")
    func deadlineCoversBody() async throws {
        let hub = ReachabilityHub()
        let updates = hub.updates()
        let telemetry = RecordingTelemetry()
        let server = StubServer(reply: .slowBody(status: 200, headers: ["Content-Type": "image/webp"], body: Data([7]), bodyDelay: .seconds(10)))
        let error = await httpError {
            _ = try await client(server, hub: hub, telemetry: telemetry).send(HouseholdRequest(path: "/v1/photos/p", timeout: .milliseconds(200)))
        }
        #expect(error == HouseholdHttpError(status: 0, code: "timeout"))
        // A timeout reports offline but, as in RN, logs nothing.
        #expect(telemetry.entries.isEmpty)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .offline)
    }

    @Test("a transport failure is (0, offline), reports offline and logs its class", arguments: [
        URLError.Code.notConnectedToInternet, .cannotConnectToHost, .timedOut, .badServerResponse,
    ])
    func transportFailure(code: URLError.Code) async throws {
        let hub = ReachabilityHub()
        let updates = hub.updates()
        let telemetry = RecordingTelemetry()
        let server = StubServer(reply: .failure(code, delay: nil))
        let error = await httpError { _ = try await client(server, hub: hub, telemetry: telemetry).listSpaces() }
        #expect(error == HouseholdHttpError(status: 0, code: "offline"))
        #expect(telemetry.entries == [.init(level: "error", name: "household_fetch_failed", payload: ["errorClass": .string("URLError")])])
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .offline)
    }

    @Test("a cancelled caller gets CancellationError and nothing is reported")
    func cancellation() async throws {
        let hub = ReachabilityHub()
        let telemetry = RecordingTelemetry()
        let server = StubServer(reply: .json(200, "{}", delay: .seconds(10)))
        let household = client(server, hub: hub, telemetry: telemetry)
        let reported = Mutex<[Reachability]>([])
        let updates = hub.updates()
        let listener = Task {
            for await value in updates { reported.withLock { $0.append(value) } }
        }
        let task = Task { try await household.listSpaces() }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await Task.sleep(for: .milliseconds(50))
        listener.cancel()
        #expect(reported.withLock { $0 }.isEmpty)
        #expect(telemetry.entries.isEmpty)
    }

    @Test("a non-JSON 5xx page is (status, invalid_json); a Cloudflare 530 page also reports offline")
    func nonJSONErrors() async throws {
        let hub = ReachabilityHub()
        let updates = hub.updates()
        let page = StubServer(reply: .text(530, "<!DOCTYPE html><title>Origin is unreachable</title>", contentType: "text/html"))
        #expect(await httpError { _ = try await client(page, hub: hub).listSpaces() } == HouseholdHttpError(status: 530, code: "invalid_json"))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .offline)
        let hono = StubServer(reply: .text(500, "Internal Server Error"))
        #expect(await httpError { _ = try await client(hono).listSpaces() } == HouseholdHttpError(status: 500, code: "invalid_json"))
    }

    @Test("409 bodies coerce updatedAt as JS Number() does", arguments: [
        (#"{"updatedAt":11}"#, Int64?.some(11)), (#"{"updatedAt":null}"#, 0), (#"{"updatedAt":"11"}"#, 11),
        (#"{"updatedAt":"junk"}"#, nil), (#"{"error":"conflict"}"#, nil), ("", nil),
    ])
    func conflictCoercion(body: String, updatedAt: Int64?) async {
        let server = StubServer(reply: .json(409, body))
        await #expect(throws: ConflictError(updatedAt: updatedAt)) {
            _ = try await client(server).updateItem(id: "i", .init(name: "x"))
        }
    }

    @Test("an error code is String(body.error), or http_<status> without one")
    func errorCodes() async {
        let numeric = StubServer(reply: .json(400, #"{"error":42}"#))
        #expect(await httpError { _ = try await client(numeric).listSpaces() } == HouseholdHttpError(status: 400, code: "42"))
        let none = StubServer(reply: .json(418, #"{"message":"teapot"}"#))
        #expect(await httpError { _ = try await client(none).listSpaces() } == HouseholdHttpError(status: 418, code: "http_418"))
    }

    @Test("a 204 answers {} without reading a body")
    func noContent() async throws {
        let server = StubServer(reply: .status(204))
        try await client(server).revokeDevice(id: "x")
        #expect(try await client(server).unbindLabel(containerId: "c"))
    }

    @Test("byte bodies go as application/octet-stream")
    func byteBodies() async throws {
        let server = StubServer(reply: .json(201, "{}"))
        _ = try await client(server).importPhoto(id: "p", bytes: Data([9]))
        let request = try #require(server.lastRequest)
        #expect(request.header("content-type") == "application/octet-stream")
        #expect(request.body == Data([9]))
    }

    @Test("withSession keeps the transport and hub")
    func withSession() async throws {
        let hub = ReachabilityHub()
        let updates = hub.updates()
        let server = StubServer(reply: .json(200, "{}"))
        let paired = client(server, token: nil, hub: hub).withSession(origin: "https://box.example", token: "new")
        _ = try await paired.listSpaces()
        #expect(server.lastRequest?.line == "GET https://box.example/v1/spaces")
        #expect(server.lastRequest?.header("authorization") == "Bearer new")
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .ok)
    }
}
