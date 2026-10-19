import Foundation
import InventoryTestSupport
import Testing
@testable import InventoryStorage

/// DECISIONS U11: only `Caches/{ImageManipulator,Camera,ImagePicker}` and `label-*.png` go.
@Suite("TemporaryCachePurge")
struct TemporaryCachePurgeTests {
    static func populate(_ container: TemporaryDirectory) throws {
        for path in [
            "Library/Caches/ImageManipulator/2C1B0A9F.webp",
            "Library/Caches/Camera/0F1E2D3C.jpg",
            "Library/Caches/ImagePicker/3A4B5C6D.heic",
            "Library/Caches/ImagePicker/nested/deeper.png",
            "Library/Caches/label-DRW-7K2M.png",
            "Library/Caches/label-label.png",
            "Library/Caches/household-photos/a1b2.webp",
            "Library/Caches/labels.png",
            "Library/Caches/label-DRW-7K2M.jpg",
            "Library/Caches/my-label-1.png",
            "Library/Caches/com.wystudio.inventory/Cache.db",
            "Documents/item-photos/3f1c.webp",
            "Library/Application Support/com.wystudio.inventory/RCTAsyncLocalStorage_V1/manifest.json",
        ] {
            try container.write(Data("x".utf8), to: path)
        }
    }

    @Test("purges the three RN temporary directories and the label share pictures, nothing else")
    func purgesOnlyTemporaries() throws {
        let container = try TemporaryDirectory()
        try Self.populate(container)

        let removed = TemporaryCachePurge(caches: container.caches).purge()

        #expect(Set(removed.map(\.lastPathComponent))
            == ["ImageManipulator", "Camera", "ImagePicker", "label-DRW-7K2M.png", "label-label.png"])
        for gone in ["ImageManipulator", "Camera", "ImagePicker", "label-DRW-7K2M.png", "label-label.png"] {
            #expect(!container.exists("Library/Caches/" + gone), "\(gone)")
        }
        for kept in [
            "Library/Caches/household-photos/a1b2.webp",
            "Library/Caches/labels.png",
            "Library/Caches/label-DRW-7K2M.jpg",
            "Library/Caches/my-label-1.png",
            "Library/Caches/com.wystudio.inventory/Cache.db",
            "Documents/item-photos/3f1c.webp",
            "Library/Application Support/com.wystudio.inventory/RCTAsyncLocalStorage_V1/manifest.json",
        ] {
            #expect(container.exists(kept), "\(kept)")
        }
    }

    @Test("an empty or missing Caches directory is fine")
    func nothingToPurge() throws {
        let container = try TemporaryDirectory()
        #expect(TemporaryCachePurge(caches: container.caches).purge().isEmpty)
    }

    @Test("runs once per install")
    func runsOnce() throws {
        let container = try TemporaryDirectory()
        let suite = try TemporaryDefaults()
        try Self.populate(container)
        let purge = TemporaryCachePurge(caches: container.caches)

        #expect(purge.runIfNeeded(defaults: suite.defaults).count == 5)
        #expect(suite.defaults.integer(forKey: TemporaryCachePurge.markerKey) == 1)

        try container.write(Data("x".utf8), to: "Library/Caches/label-NEW.png")
        #expect(purge.runIfNeeded(defaults: suite.defaults).isEmpty)
        #expect(container.exists("Library/Caches/label-NEW.png"))
    }
}
