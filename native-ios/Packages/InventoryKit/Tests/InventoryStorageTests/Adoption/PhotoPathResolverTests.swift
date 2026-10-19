import Foundation
import Testing
@testable import InventoryStorage

/// 02 §11.2 #6: the stored URI shapes of 02 §3.2, resolved against a fresh container whose UUID
/// differs from the one in the stored paths (`Fixtures/adoption/photo-path-cases.json`).
@Suite("PhotoPathResolver")
struct PhotoPathResolverTests {
    struct Cases: Decodable {
        struct Case: Decodable {
            let name: String
            let stored: String
            let expected: String?
        }
        let files: [String]
        let cases: [Case]
    }

    static func resolver(_ container: TemporaryContainer) -> PhotoPathResolver {
        PhotoPathResolver(documents: container.documents, caches: container.caches)
    }

    @Test("resolves every stored shape by file name in the current container")
    func fixtureCases() throws {
        let fixture = try AdoptionFixtures.decode(Cases.self, from: "photo-path-cases.json")
        let container = try TemporaryContainer()
        for file in fixture.files {
            try container.write(Data(file.utf8), to: file)
        }
        let resolver = Self.resolver(container)
        let containerURI = container.root.absoluteString.hasSuffix("/")
            ? String(container.root.absoluteString.dropLast()) : container.root.absoluteString
        for testCase in fixture.cases {
            let stored = testCase.stored.replacingOccurrences(of: "{container}", with: containerURI)
            let resolved = resolver.resolve(stored)
            let expected = testCase.expected.map { container.root.appending(path: $0).path }
            #expect(resolved?.path == expected, "\(testCase.name)")
            if let resolved {
                #expect(try Data(contentsOf: resolved) == Data((testCase.expected ?? "").utf8), "\(testCase.name)")
            }
        }
    }

    @Test("nil is not a photo")
    func nilStored() throws {
        let container = try TemporaryContainer()
        #expect(Self.resolver(container).resolve(nil) == nil)
    }

    @Test("prefers the stored path when it exists, even outside the photo directories")
    func sameContainerAnywhere() throws {
        let container = try TemporaryContainer()
        let file = try container.write(Data("x".utf8), to: "Documents/elsewhere/x.webp")
        #expect(Self.resolver(container).resolve(file.absoluteString)?.path == file.path)
    }

    @Test("a directory is never a photo, so a caller that deletes what resolves cannot remove one")
    func directoriesAreNotPhotos() throws {
        let container = try TemporaryContainer()
        try container.write(Data("x".utf8), to: "Documents/item-photos/a.webp")
        try container.createDirectory("Documents/item-photos/sub.webp")
        try container.write(Data("db".utf8), to: "Documents/SQLite/inventory.db")
        let resolver = Self.resolver(container)
        let documents = container.documents.absoluteString  // ends with "/"
        for stored in [
            documents + "item-photos",              // the photo directory itself
            documents + "item-photos/",             // a directory path (expo's File refuses it)
            documents + "item-photos/..",           // standardizes to Documents
            documents + "item-photos/a.webp/..",    // standardizes to item-photos
            documents + "item-photos/.",
            documents + "item-photos/sub.webp",     // a directory with a photo's name
            "file:///var/mobile/Containers/Data/Application/OLD/Documents/item-photos/sub.webp",
            "file:///var/mobile/Containers/Data/Application/OLD/Documents/item-photos/..",
            "file:///var/mobile/Containers/Data/Application/OLD/Documents/item-photos/.",
            "file:///data/user/0/com.wystudio.inventory/files/item-photos/",
        ] {
            #expect(resolver.resolve(stored) == nil, "\(stored)")
        }
        #expect(container.exists("Documents/item-photos/a.webp"))
    }

    @Test("dot segments are standardized away like expo's File(uri) does")
    func standardizesDotSegments() throws {
        let container = try TemporaryContainer()
        try container.write(Data("x".utf8), to: "Documents/item-photos/a.webp")
        let resolver = Self.resolver(container)
        let expected = container.documents.appending(path: "item-photos/a.webp").path
        let documents = container.documents.absoluteString
        #expect(resolver.resolve(documents + "item-photos/./a.webp")?.path == expected)
        #expect(resolver.resolve(documents + "elsewhere/../item-photos/a.webp")?.path == expected)
        #expect(resolver.resolve(
            "file:///var/mobile/Containers/Data/Application/OLD/Documents/x/../item-photos/a.webp")?.path == expected)
    }

    @Test("a rebased file that is gone is nil, so callers treat the bytes as missing")
    func goneAfterRebase() throws {
        let container = try TemporaryContainer()
        try container.createDirectory("Documents/item-photos")
        let stored = "file:///var/mobile/Containers/Data/Application/OLD/Documents/item-photos/gone.webp"
        #expect(Self.resolver(container).resolve(stored) == nil)
    }

    @Test("storedURI is the absolute shape-1 URI in the current container")
    func storedURI() throws {
        let container = try TemporaryContainer()
        let resolver = Self.resolver(container)
        let uri = resolver.storedURI(forPhotoNamed: "x.webp")
        #expect(uri == container.documents.appending(path: "item-photos/x.webp").absoluteString)
        #expect(uri.hasPrefix("file:///"))
        #expect(uri.hasSuffix("/Documents/item-photos/x.webp"))
        // What native writes, it resolves.
        try container.write(Data(), to: "Documents/item-photos/x.webp")
        #expect(resolver.resolve(uri)?.path == container.documents.appending(path: "item-photos/x.webp").path)
    }

    @Test("storedURI with the live directories matches URL.documentsDirectory (02 §11.2 #6)")
    func storedURILive() {
        #expect(PhotoPathResolver().storedURI(forPhotoNamed: "x.webp")
            == URL.documentsDirectory.appending(path: "item-photos/x.webp").absoluteString)
    }

    @Test("the photo directories sit where RN put them")
    func directories() throws {
        let container = try TemporaryContainer()
        let resolver = Self.resolver(container)
        #expect(resolver.itemPhotosDirectory.path == container.root.appending(path: "Documents/item-photos").path)
        #expect(resolver.householdPhotosDirectory.path
            == container.root.appending(path: "Library/Caches/household-photos").path)
    }
}
