import Foundation
import InventoryCore
import InventoryNetwork
import InventoryStorage
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryServices

// RN has no tests for src/services/household/photoCache.ts; these pin 04 §8 and the native
// additions it recommends (§16.1: hit and miss, atomic write; coalescing).

private struct PhotoCacheFixture {
    let directory: TemporaryDirectory
    let cache: HouseholdPhotoCache
    let server: StubServer
    let client: HouseholdClient

    init(hub: ReachabilityHub? = nil, _ handler: @escaping StubServer.Handler) throws {
        directory = try TemporaryDirectory()
        cache = HouseholdPhotoCache(resolver: PhotoPathResolver(documents: directory.documents, caches: directory.caches))
        server = StubServer(handler)
        client = server.householdClient(token: "tok", hub: hub)
    }

    func file(_ name: String) -> URL {
        directory.caches.appending(path: "household-photos/\(name)", directoryHint: .notDirectory)
    }
}

@Suite("HouseholdPhotoCache")
struct HouseholdPhotoCacheTests {
    @Test("a miss downloads the photo with the token, writes <id>.webp and returns its file URI")
    func missDownloads() async throws {
        let fixture = try PhotoCacheFixture { _ in .bytes(200, Data([1, 2, 3]), headers: ["Content-Type": "image/webp"]) }
        let uri = await fixture.cache.resolve("p1", kind: .full, client: fixture.client)
        #expect(uri == fixture.file("p1.webp").absoluteString)
        #expect(try Data(contentsOf: fixture.file("p1.webp")) == Data([1, 2, 3]))
        let request = try #require(fixture.server.lastRequest)
        #expect(request.line == "GET https://inventory.wystudio.be/v1/photos/p1")
        #expect(request.header("authorization") == "Bearer tok")
        #expect(request.header("accept") == "application/json")
    }

    @Test("a thumbnail asks for ?thumb=1 and is cached as <id>-thumb.webp")
    func thumbnail() async throws {
        let fixture = try PhotoCacheFixture { _ in .bytes(200, Data([9])) }
        let uri = await fixture.cache.resolve("p1", kind: .thumb, client: fixture.client)
        #expect(uri == fixture.file("p1-thumb.webp").absoluteString)
        #expect(fixture.server.lastRequest?.path == "/v1/photos/p1?thumb=1")
    }

    @Test("a hit returns the cached file without asking the server")
    func hitSkipsTheNetwork() async throws {
        let fixture = try PhotoCacheFixture { _ in .bytes(200, Data([1])) }
        try fixture.directory.write(Data([5, 5]), to: "Library/Caches/household-photos/p1.webp")
        let uri = await fixture.cache.resolve("p1", kind: .full, client: fixture.client)
        #expect(uri == fixture.file("p1.webp").absoluteString)
        #expect(fixture.server.requests.isEmpty)
        #expect(try Data(contentsOf: fixture.file("p1.webp")) == Data([5, 5]))
    }

    @Test("an empty file left by an interrupted RN write counts as missing and is replaced")
    func emptyFileIsAMiss() async throws {
        let fixture = try PhotoCacheFixture { _ in .bytes(200, Data([1, 2])) }
        try fixture.directory.write(Data(), to: "Library/Caches/household-photos/p1.webp")
        let uri = await fixture.cache.resolve("p1", kind: .full, client: fixture.client)
        #expect(uri == fixture.file("p1.webp").absoluteString)
        #expect(try Data(contentsOf: fixture.file("p1.webp")) == Data([1, 2]))
        #expect(fixture.server.requests.count == 1)
    }

    @Test("any non-2xx answer is nil and leaves no file", arguments: [404, 500, 503, 530])
    func failureIsNil(status: Int) async throws {
        let fixture = try PhotoCacheFixture { _ in .json(status, #"{"error":"x"}"#) }
        #expect(await fixture.cache.resolve("p1", kind: .full, client: fixture.client) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.file("p1.webp").path))
    }

    @Test("no answer at all is nil, and the download reports reachability like any request")
    func offlineIsNil() async throws {
        let hub = ReachabilityHub()
        let reports = hub.updates()
        let fixture = try PhotoCacheFixture(hub: hub) { _ in .failure(.notConnectedToInternet, delay: nil) }
        #expect(await fixture.cache.resolve("p1", kind: .thumb, client: fixture.client) == nil)
        var iterator = reports.makeAsyncIterator()
        #expect(await iterator.next() == .offline)
    }

    @Test("concurrent requests for the same photo share one download")
    func coalesces() async throws {
        let fixture = try PhotoCacheFixture { _ in .response(status: 200, headers: [:], body: Data([3]), delay: .milliseconds(200)) }
        async let first = fixture.cache.resolve("p1", kind: .full, client: fixture.client)
        async let second = fixture.cache.resolve("p1", kind: .full, client: fixture.client)
        async let thumb = fixture.cache.resolve("p1", kind: .thumb, client: fixture.client)
        let uris = await [first, second, thumb]
        #expect(uris == [fixture.file("p1.webp").absoluteString, fixture.file("p1.webp").absoluteString, fixture.file("p1-thumb.webp").absoluteString])
        #expect(fixture.server.requests.count == 2)
    }

    @Test("a photo id that is not a plain file name is refused without a request", arguments: ["", ".", "..", "../escape", "a/b"])
    func unsafeIds(photoId: String) async throws {
        let fixture = try PhotoCacheFixture { _ in .bytes(200, Data([1])) }
        #expect(await fixture.cache.resolve(photoId, kind: .full, client: fixture.client) == nil)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test("remember copies a capture and its thumbnail under the server's photo id, replacing old files")
    func rememberCopies() async throws {
        let fixture = try PhotoCacheFixture { _ in .bytes(200, Data([1])) }
        let full = try fixture.directory.write(Data([1, 2]), to: "Documents/item-photos/cap.webp")
        let thumb = try fixture.directory.write(Data([3]), to: "Documents/item-photos/cap-thumb.webp")
        try fixture.directory.write(Data([9, 9, 9]), to: "Library/Caches/household-photos/srv.webp")

        await fixture.cache.remember(photoId: "srv", sourceURI: full.absoluteString, thumbURI: thumb.absoluteString)
        #expect(try Data(contentsOf: fixture.file("srv.webp")) == Data([1, 2]))
        #expect(try Data(contentsOf: fixture.file("srv-thumb.webp")) == Data([3]))
        // The next read is a hit.
        #expect(await fixture.cache.resolve("srv", kind: .thumb, client: fixture.client) == fixture.file("srv-thumb.webp").absoluteString)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test("remember finds a capture whose stored URI points at an old container, and skips missing files")
    func rememberResolvesStoredURIs() async throws {
        let fixture = try PhotoCacheFixture { _ in .bytes(200, Data([1])) }
        try fixture.directory.write(Data([4]), to: "Documents/item-photos/moved.webp")
        let stale = "file:///var/mobile/Containers/Data/Application/OLD/Documents/item-photos/moved.webp"
        await fixture.cache.remember(photoId: "a", sourceURI: stale, thumbURI: "")
        #expect(try Data(contentsOf: fixture.file("a.webp")) == Data([4]))
        #expect(!FileManager.default.fileExists(atPath: fixture.file("a-thumb.webp").path))

        await fixture.cache.remember(photoId: "b", sourceURI: "file:///nowhere/item-photos/gone.webp", thumbURI: nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.file("b.webp").path))
    }
}
