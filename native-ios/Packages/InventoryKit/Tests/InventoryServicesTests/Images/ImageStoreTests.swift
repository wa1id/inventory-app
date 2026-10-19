import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import InventoryServices
import InventoryStorage

@Suite("ImageStore.storeItemPhoto")
struct StoreItemPhotoTests {
    @Test("names both files by one fresh lowercase UUID under Documents/item-photos, as absolute file URIs")
    func namesFiles() async throws {
        let container = try PhotoContainer()
        let store = ImageStore(resolver: container.resolver)
        let stored = try await store.storeItemPhoto(.data(TestImages.jpeg(TestImages.marked(width: 800, height: 600))))

        let full = try #require(URL(string: stored.uri))
        let thumb = try #require(URL(string: stored.thumbUri))
        #expect(full.isFileURL && thumb.isFileURL)
        let id = String(full.lastPathComponent.dropLast(".webp".count))
        #expect(isLowercaseV4UUID(id))
        #expect(full.lastPathComponent == "\(id).webp")
        #expect(thumb.lastPathComponent == "\(id)-thumb.webp")
        // Shape 1 of 02 §3.2, exactly what PhotoPathResolver writes and RN wrote.
        #expect(stored.uri == container.resolver.storedURI(forPhotoNamed: "\(id).webp"))
        #expect(stored.thumbUri == container.resolver.storedURI(forPhotoNamed: "\(id)-thumb.webp"))
        #expect(stored.uri.hasPrefix("file:///"))
        #expect(full.path == container.photoDirectory.appending(path: "\(id).webp").path)
        #expect(container.photoFiles() == ["\(id)-thumb.webp", "\(id).webp"].sorted())
    }

    @Test("gives every photo a new name")
    func freshNames() async throws {
        let container = try PhotoContainer()
        let store = ImageStore(resolver: container.resolver)
        let jpeg = try TestImages.jpeg(TestImages.marked(width: 400, height: 300))
        let first = try await store.storeItemPhoto(.data(jpeg))
        let second = try await store.storeItemPhoto(.data(jpeg))

        #expect(first.uri != second.uri)
        #expect(container.photoFiles().count == 4)
    }

    @Test("records the stored file's exact pixel size and byte size")
    func recordsSizes() async throws {
        let container = try PhotoContainer()
        let store = container.store()
        let stored = try await store.storeItemPhoto(.data(TestImages.jpeg(TestImages.marked(width: 4032, height: 3024))))

        let fullURL = try #require(container.resolver.resolve(stored.uri))
        let data = try Data(contentsOf: fullURL)
        #expect(stored.width == 1400 && stored.height == 1050)
        #expect(try Inspect.vp8Size(data) == PixelSize(width: stored.width, height: stored.height))
        let decoded = try Inspect.image(data)
        #expect(decoded.width == stored.width && decoded.height == stored.height)
        #expect(stored.byteSize == data.count)
        let attributes = try FileManager.default.attributesOfItem(atPath: fullURL.path)
        #expect((attributes[.size] as? NSNumber)?.intValue == stored.byteSize)
    }

    @Test("bounds the full image to 1400 and the thumbnail to 320 on the longer edge", arguments: [
        (4032, 3024, PixelSize(width: 1400, height: 1050), PixelSize(width: 320, height: 240)),
        (3024, 4032, PixelSize(width: 1050, height: 1400), PixelSize(width: 240, height: 320)),
        (1179, 2556, PixelSize(width: 646, height: 1400), PixelSize(width: 148, height: 320)),
        (1000, 500, PixelSize(width: 1000, height: 500), PixelSize(width: 320, height: 160)),
    ])
    func boundsEdges(width: Int, height: Int, full: PixelSize, thumb: PixelSize) async throws {
        let container = try PhotoContainer()
        let stored = try await container.store().storeItemPhoto(.data(TestImages.jpeg(TestImages.marked(width: width, height: height))))

        #expect(PixelSize(width: stored.width, height: stored.height) == full)
        let thumbData = try Data(contentsOf: #require(container.resolver.resolve(stored.thumbUri)))
        #expect(try Inspect.vp8Size(thumbData) == thumb)
        #expect(max(thumb.width, thumb.height) <= ImageScaling.thumbnailDimension)
    }

    @Test("re-encodes a small image as WebP without enlarging it")
    func reencodesSmallImage() async throws {
        let container = try PhotoContainer()
        let png = try TestImages.encode(TestImages.marked(width: 300, height: 200), as: .png)
        let stored = try await container.store().storeItemPhoto(.data(png))

        #expect(stored.width == 300 && stored.height == 200)
        for uri in [stored.uri, stored.thumbUri] {
            let data = try Data(contentsOf: #require(container.resolver.resolve(uri)))
            #expect(Inspect.typeIdentifier(data) == UTType.webP.identifier)
            #expect(try Inspect.vp8Size(data) == PixelSize(width: 300, height: 200))
        }
    }

    @Test("strips EXIF and GPS from a camera JPEG and bakes in its orientation")
    func stripsMetadataAndBakesOrientation() async throws {
        // 1600×1200 stored, orientation 6 (shown 1200×1600), GPS + EXIF + TIFF, red block in the
        // stored top-left corner, which shows top-right.
        let fixture = try ImageFixtures.data("gps-orientation-6.jpg")
        let source = try Inspect.properties(fixture)
        try #require(source[kCGImagePropertyGPSDictionary as String] != nil, "the fixture must carry GPS")
        try #require(source[kCGImagePropertyExifDictionary as String] != nil, "the fixture must carry EXIF")
        try #require(source[kCGImagePropertyOrientation as String] as? Int == 6)

        let container = try PhotoContainer()
        let stored = try await container.store().storeItemPhoto(.data(fixture))

        #expect(stored.width == 1050 && stored.height == 1400)
        for (uri, size) in [(stored.uri, PixelSize(width: 1050, height: 1400)), (stored.thumbUri, PixelSize(width: 240, height: 320))] {
            let data = try Data(contentsOf: #require(container.resolver.resolve(uri)))
            // One VP8 chunk: there is nowhere for EXIF, XMP or GPS to hide.
            #expect(try Inspect.webPChunks(data) == ["VP8 "])
            let properties = try Inspect.properties(data)
            #expect(properties[kCGImagePropertyGPSDictionary as String] == nil)
            #expect(properties[kCGImagePropertyExifDictionary as String] == nil)
            #expect(properties[kCGImagePropertyTIFFDictionary as String] == nil)
            #expect((properties[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1)
            #expect(data.range(of: Data("FixtureCam".utf8)) == nil)
            #expect(data.range(of: Data("Exif".utf8)) == nil)

            let decoded = try Inspect.image(data)
            #expect(decoded.width == size.width && decoded.height == size.height)
            #expect(try Inspect.redCorner(decoded) == .topRight)
            #expect(try Inspect.pixel(decoded, fx: 0.1, fy: 0.1).isClose(to: .grey, tolerance: 20))
        }
    }

    @Test("reads a file without trusting its extension, and leaves it in place")
    func storesFile() async throws {
        let container = try PhotoContainer()
        let source = try container.write(
            TestImages.jpeg(TestImages.marked(width: 2000, height: 1500), orientation: 3), to: "Library/Caches/pick.webp")
        let stored = try await container.store().storeItemPhoto(.file(source))

        #expect(stored.width == 1400 && stored.height == 1050)
        let decoded = try Inspect.image(at: #require(container.resolver.resolve(stored.uri)))
        #expect(try Inspect.redCorner(decoded) == .bottomRight)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("stores decoded pixels as they are")
    func storesImage() async throws {
        let container = try PhotoContainer()
        let stored = try await container.store().storeItemPhoto(.image(TestImages.marked(width: 2800, height: 1400)))

        #expect(stored.width == 1400 && stored.height == 700)
        let decoded = try Inspect.image(at: #require(container.resolver.resolve(stored.thumbUri)))
        #expect(decoded.width == 320 && decoded.height == 160)
        #expect(try Inspect.redCorner(decoded) == .topLeft)
    }

    @Test("stores a HEIC capture upright", .enabled(if: TestImages.canEncodeHEIC))
    func storesHEIC() async throws {
        let heic = try TestImages.encode(
            TestImages.marked(width: 4032, height: 3024), as: .heic, properties: [kCGImagePropertyOrientation: 6])
        let container = try PhotoContainer()
        let stored = try await container.store().storeItemPhoto(.data(heic))

        #expect(stored.width == 1050 && stored.height == 1400)
        let decoded = try Inspect.image(at: #require(container.resolver.resolve(stored.uri)))
        #expect(try Inspect.redCorner(decoded) == .topRight)
    }

    @Test("crops to the preview aspect before scaling")
    func cropsToPreview() async throws {
        let container = try PhotoContainer()
        let stored = try await container.store().storeItemPhoto(
            .data(TestImages.jpeg(TestImages.marked(width: 3024, height: 4032))),
            cropToAspect: CGSize(width: 393, height: 852))

        #expect(stored.width == 646 && stored.height == 1400)
        let thumb = try Data(contentsOf: #require(container.resolver.resolve(stored.thumbUri)))
        #expect(try Inspect.vp8Size(thumb) == PixelSize(width: 148, height: 320))
    }

    @Test("encodes the full image at quality 0.8 and the thumbnail at 0.7")
    func encodesAtRNQualities() async throws {
        let image = try TestImages.marked(width: 2100, height: 1400)
        let container = try PhotoContainer()
        let stored = try await container.store().storeItemPhoto(.image(image))

        // libwebp is deterministic: re-encoding the same pixels must give the stored bytes.
        let decoded = DecodedImage(image: image, fullSize: PixelSize(width: 2100, height: 1400))
        let whole = PixelRect(decoded.fullSize)
        let full = try ImagePipeline.rendition(of: decoded, crop: whole, maxEdge: 1400, quality: 0.8)
        let thumb = try ImagePipeline.rendition(of: decoded, crop: whole, maxEdge: 320, quality: 0.7)
        #expect(try Data(contentsOf: #require(container.resolver.resolve(stored.uri))) == full.data)
        #expect(try Data(contentsOf: #require(container.resolver.resolve(stored.thumbUri))) == thumb.data)
    }

    @Test("fails with one error and writes nothing for bytes that are not an image")
    func failsCleanly() async throws {
        let container = try PhotoContainer()
        let store = container.store()
        await #expect(throws: ImageStoreError.couldNotProcess) {
            try await store.storeItemPhoto(.data(Data("not an image".utf8)))
        }
        await #expect(throws: ImageStoreError.couldNotProcess) {
            try await store.storeItemPhoto(.file(container.root.appending(path: "missing.jpg")))
        }
        #expect(container.photoFiles().isEmpty)
    }

    @Test("processes a burst one photo at a time")
    func serialisesBurst() async throws {
        let container = try PhotoContainer()
        let probe = OverlapProbe()
        let store = container.store(makePhotoId: {
            probe.enter()
            Thread.sleep(forTimeInterval: 0.02)
            probe.leave()
            return UUID().uuidString.lowercased()
        })
        let jpeg = try TestImages.jpeg(TestImages.marked(width: 800, height: 600))

        let stored = try await withThrowingTaskGroup(of: StoredImage.self) { group in
            for _ in 0..<4 {
                group.addTask { try await store.storeItemPhoto(.data(jpeg)) }
            }
            return try await group.reduce(into: [StoredImage]()) { $0.append($1) }
        }

        #expect(Set(stored.map(\.uri)).count == 4)
        #expect(container.photoFiles().count == 8)
        #expect(probe.peak == 1)
    }

    /// Counts how many callers are inside at once.
    final class OverlapProbe: Sendable {
        private let state = Mutex((active: 0, peak: 0))

        func enter() {
            state.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
        }

        func leave() {
            state.withLock { $0.active -= 1 }
        }

        var peak: Int { state.withLock { $0.peak } }
    }
}

@Suite("ImageStore.writeStoredPhoto")
struct WriteStoredPhotoTests {
    static let rowId = "0b7c6f1e-4d2a-4c3b-9e8f-1a2b3c4d5e6f"

    @Test("writes the bytes verbatim under the row id and regenerates the thumbnail")
    func writesVerbatim() async throws {
        let container = try PhotoContainer()
        let store = container.store()
        let original = try await store.storeItemPhoto(.image(TestImages.marked(width: 1400, height: 1050)))
        let bytes = try #require(store.readStoredPhoto(original.uri))

        let restored = try await store.writeStoredPhoto(photoId: Self.rowId, bytes: bytes)

        #expect(restored.uri == container.resolver.storedURI(forPhotoNamed: "\(Self.rowId).webp"))
        #expect(restored.thumbUri == container.resolver.storedURI(forPhotoNamed: "\(Self.rowId)-thumb.webp"))
        #expect(try Data(contentsOf: #require(container.resolver.resolve(restored.uri))) == bytes)
        #expect(restored.width == 1400 && restored.height == 1050)
        #expect(restored.byteSize == bytes.count)
        let thumb = try Data(contentsOf: #require(container.resolver.resolve(restored.thumbUri)))
        #expect(try Inspect.vp8Size(thumb) == PixelSize(width: 320, height: 240))
    }

    @Test("keeps a legacy JPEG as it is under the .webp name, reporting its upright size")
    func keepsLegacyJPEG() async throws {
        let container = try PhotoContainer()
        // Larger than 1400 and turned: never resized, and the size reported upright (RN reads it
        // after ImageManipulator bakes the orientation in).
        let jpeg = try ImageFixtures.data("gps-orientation-6.jpg")
        let restored = try await container.store().writeStoredPhoto(photoId: Self.rowId, bytes: jpeg)

        let written = try Data(contentsOf: #require(container.resolver.resolve(restored.uri)))
        #expect(written == jpeg)
        #expect(Inspect.typeIdentifier(written) == UTType.jpeg.identifier)
        #expect(restored.width == 1200 && restored.height == 1600)
        let thumb = try Data(contentsOf: #require(container.resolver.resolve(restored.thumbUri)))
        #expect(Inspect.typeIdentifier(thumb) == UTType.webP.identifier)
        #expect(try Inspect.webPChunks(thumb) == ["VP8 "])
        #expect(try Inspect.vp8Size(thumb) == PixelSize(width: 240, height: 320))
        #expect(try Inspect.redCorner(Inspect.image(thumb)) == .topRight)
    }

    @Test("overwrites the same two files when a restore runs again")
    func idempotent() async throws {
        let container = try PhotoContainer()
        let store = container.store()
        let first = try TestImages.jpeg(TestImages.marked(width: 600, height: 400))
        let second = try TestImages.jpeg(TestImages.marked(width: 400, height: 600))
        _ = try await store.writeStoredPhoto(photoId: Self.rowId, bytes: first)
        let again = try await store.writeStoredPhoto(photoId: Self.rowId, bytes: second)

        #expect(container.photoFiles() == ["\(Self.rowId)-thumb.webp", "\(Self.rowId).webp"])
        #expect(try Data(contentsOf: #require(container.resolver.resolve(again.uri))) == second)
        #expect(again.width == 400 && again.height == 600)
    }

    @Test("propagates a decode failure, leaving the full file and no thumbnail, as RN does")
    func decodeFailure() async throws {
        let container = try PhotoContainer()
        let store = container.store()
        await #expect(throws: ImageStoreError.undecodable) {
            try await store.writeStoredPhoto(photoId: Self.rowId, bytes: Data("not an image".utf8))
        }
        #expect(container.photoFiles() == ["\(Self.rowId).webp"])
    }

    @Test("refuses an id that is not a plain file name", arguments: ["", ".", "..", "../escape", "a/b", "x\0y"])
    func refusesPathIds(id: String) async throws {
        let container = try PhotoContainer()
        let store = container.store()
        let jpeg = try TestImages.jpeg(TestImages.marked(width: 40, height: 30))
        await #expect(throws: ImageStoreError.invalidPhotoId) {
            try await store.writeStoredPhoto(photoId: id, bytes: jpeg)
        }
        #expect(container.photoFiles().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: container.documents.appending(path: "escape.webp").path))
    }
}

@Suite("ImageStore reads and deletes")
struct StoredPhotoFileTests {
    /// The same URI as written by an older container (the UUID path segment differs).
    static func stale(_ uri: String, container: PhotoContainer) -> String {
        let root = container.root.absoluteString
        return uri.replacingOccurrences(of: root, with: "file:///var/mobile/Containers/Data/Application/0E1D2C3B-4A59-4687-9A0B-C1D2E3F40516/")
    }

    @Test("reads a stored photo's bytes")
    func reads() async throws {
        let container = try PhotoContainer()
        let store = container.store()
        let stored = try await store.storeItemPhoto(.image(TestImages.marked(width: 64, height: 48)))
        let bytes = try #require(store.readStoredPhoto(stored.uri))
        #expect(bytes == (try Data(contentsOf: #require(container.resolver.resolve(stored.uri)))))
    }

    @Test("finds a photo whose stored path names an older container")
    func readsStalePath() async throws {
        let container = try PhotoContainer()
        let store = container.store()
        let stored = try await store.storeItemPhoto(.image(TestImages.marked(width: 64, height: 48)))
        let stale = Self.stale(stored.uri, container: container)
        try #require(stale != stored.uri)

        #expect(store.readStoredPhoto(stale) == store.readStoredPhoto(stored.uri))
        let thumb = await store.loadStoredPhoto(Self.stale(stored.thumbUri, container: container))
        #expect(thumb?.width == 64)
    }

    @Test("returns nil for a missing file or a URI that is not a local file", arguments: [
        "missing", "r2:household/primary/photos/abc.webp", "https://example.com/abc.webp", "", "not a uri",
    ])
    func readsNothing(kind: String) async throws {
        let container = try PhotoContainer()
        let store = container.store()
        let uri = kind == "missing" ? container.resolver.storedURI(forPhotoNamed: "gone.webp") : kind
        #expect(store.readStoredPhoto(uri) == nil)
        let image = await store.loadStoredPhoto(uri)
        #expect(image == nil)
    }

    @Test("returns an empty file as empty data, not nil")
    func readsEmptyFile() throws {
        let container = try PhotoContainer()
        try container.write(Data(), to: "Documents/item-photos/empty.webp")
        let store = container.store()
        #expect(store.readStoredPhoto(container.resolver.storedURI(forPhotoNamed: "empty.webp")) == Data())
    }

    @Test("decodes a stored photo for display, downsampled")
    func loadsForDisplay() async throws {
        let container = try PhotoContainer()
        let store = container.store()
        let stored = try await store.storeItemPhoto(.image(TestImages.marked(width: 1400, height: 1050)))
        let image = try #require(await store.loadStoredPhoto(stored.uri, maxPixelSize: 700))
        #expect(image.width == 700 && image.height == 525)
        let none = await store.loadStoredPhoto(nil)
        #expect(none == nil)
    }

    @Test("deletes the full image and the thumbnail")
    func deletes() async throws {
        let container = try PhotoContainer()
        let store = container.store()
        let stored = try await store.storeItemPhoto(.image(TestImages.marked(width: 64, height: 48)))
        store.deleteStoredPhotos([stored.uri, stored.thumbUri])
        #expect(container.photoFiles().isEmpty)
    }

    @Test("deletes through a stale container path")
    func deletesStalePath() async throws {
        let container = try PhotoContainer()
        let store = container.store()
        let stored = try await store.storeItemPhoto(.image(TestImages.marked(width: 64, height: 48)))
        store.deleteStoredPhotos([Self.stale(stored.uri, container: container), Self.stale(stored.thumbUri, container: container)])
        #expect(container.photoFiles().isEmpty)
    }

    @Test("skips nil, empty, remote and missing URIs without complaint")
    func skipsUnusable() async throws {
        let container = try PhotoContainer()
        let store = container.store()
        let stored = try await store.storeItemPhoto(.image(TestImages.marked(width: 64, height: 48)))
        store.deleteStoredPhotos([
            nil, "", "r2:household/primary/photos/\(stored.uri.suffix(20))", "https://example.com/x.webp",
            container.resolver.storedURI(forPhotoNamed: "gone.webp"),
        ])
        #expect(container.photoFiles().count == 2)
    }

    @Test("never deletes a directory")
    func keepsDirectories() async throws {
        let container = try PhotoContainer()
        let store = container.store()
        _ = try await store.storeItemPhoto(.image(TestImages.marked(width: 64, height: 48)))
        store.deleteStoredPhotos([
            container.photoDirectory.absoluteString,
            container.documents.absoluteString,
            String(container.photoDirectory.absoluteString.dropLast()),
        ])
        #expect(container.photoFiles().count == 2)
    }
}

@Suite("ImageStore.hasRoomForPhoto")
struct HasRoomForPhotoTests {
    struct ProbeFailed: Error {}

    static func store(_ free: Int64?) throws -> ImageStore {
        try PhotoContainer().store(freeSpace: { free })
    }

    @Test("needs more than twice the estimate free", arguments: [
        (Int64(2_000_001), true), (Int64(2_000_000), false), (Int64(0), false), (Int64(64_000_000_000), true),
    ])
    func threshold(free: Int64, expected: Bool) throws {
        #expect(try Self.store(free).hasRoomForPhoto() == expected)
    }

    @Test("scales with the estimate")
    func estimate() throws {
        #expect(try Self.store(10_000_001).hasRoomForPhoto(estimatedBytes: 5_000_000))
        #expect(try !Self.store(10_000_000).hasRoomForPhoto(estimatedBytes: 5_000_000))
        #expect(try !Self.store(Int64.max).hasRoomForPhoto(estimatedBytes: Int64.max))
    }

    @Test("an unknown free size means no room, like JS null > n")
    func unknownMeansNoRoom() throws {
        #expect(try !Self.store(nil).hasRoomForPhoto())
    }

    @Test("a probe that throws means room, like RN's catch")
    func throwingMeansRoom() throws {
        let store = try PhotoContainer().store(freeSpace: { throw ProbeFailed() })
        #expect(store.hasRoomForPhoto())
    }

    @Test("reads the free size of the Documents volume by default")
    func defaultProbe() throws {
        let container = try PhotoContainer()
        try FileManager.default.createDirectory(at: container.documents, withIntermediateDirectories: true)
        let free = try #require(try ImageStore.systemFreeSize(of: container.documents))
        #expect(free > 0)
        #expect(ImageStore(resolver: container.resolver).hasRoomForPhoto(estimatedBytes: 1) == (free > 2))
        // A Documents directory that cannot be read throws, which counts as room.
        let missing = PhotoPathResolver(documents: container.root.appending(path: "nowhere"), caches: container.caches)
        #expect(throws: (any Error).self) { try ImageStore.systemFreeSize(of: missing.documents) }
        #expect(ImageStore(resolver: missing).hasRoomForPhoto())
    }
}
