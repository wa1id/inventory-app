import Foundation
import InventoryCore
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// The photo viewer (app/item/[id]/photo.tsx; 05 §13) as a model. RN has no tests for it.
@MainActor
@Suite("PhotoViewerModel (app/item/[id]/photo.tsx)")
struct ItemScreensPhotoViewerModelTests {
    private func loaded(_ answer: EntitiesFakeItems.Answer<ItemWithContext?>) async -> PhotoViewerModel {
        let model = PhotoViewerModel(itemId: "item-1", items: EntitiesFakeItems(reads: [answer]))
        model.focusChanged(true, revision: 0)
        await model.query.readTask?.value
        return model
    }

    private static func item(name: String = "Cordless drill", photo: String?, thumb: String?) -> ItemWithContext {
        var item = EntitiesFixtures.context(name: name)
        item.photoUri = photo
        item.photoThumbUri = thumb
        return item
    }

    @Test("shows the full photo, else the thumbnail; a photo that cannot be read is missing")
    func photo() async {
        let full = await loaded(.value(Self.item(photo: "file:///full.webp", thumb: "file:///thumb.webp")))
        #expect(full.phase == .photo(uri: "file:///full.webp"))
        #expect(full.accessibilityLabel == "Photo of Cordless drill")
        full.imageFailed("file:///full.webp")
        #expect(full.phase == .missing)

        let thumbOnly = await loaded(.value(Self.item(photo: nil, thumb: "file:///thumb.webp")))
        #expect(thumbOnly.phase == .photo(uri: "file:///thumb.webp"))

        let none = await loaded(.value(Self.item(name: "", photo: nil, thumb: nil)))
        #expect(none.phase == .missing)
        #expect(none.accessibilityLabel == L10n.Photo.a11yUnnamed)
    }

    @Test("a failed read says why in plain words; a missing item is gone")
    func states() async {
        let offline = HouseholdHttpError(status: 0, code: "offline")
        let failed = await loaded(.failure(offline))
        let described = describeError(offline, context: .read, subject: .item)
        #expect(failed.phase == .failed(title: described.title, body: described.body))
        #expect(described.title == L10n.Errors.Offline.title)

        let gone = await loaded(.value(nil))
        #expect(gone.phase == .gone)
        #expect(L10n.Errors.Gone.item == "This item is gone")
    }

    @Test("the spinner shows only once loading has lasted 180 ms")
    func spinner() async throws {
        let clock = ManualClock()
        let items = ItemScreensHeldReads()
        let model = PhotoViewerModel(itemId: "item-1", items: items, clock: clock)
        #expect(model.phase == .loading)
        model.focusChanged(true, revision: 0)
        try await clock.waitForSleepers()
        await clock.advance(by: .milliseconds(179))
        #expect(!model.spinner.value)
        await clock.advance(by: .milliseconds(1))
        #expect(model.spinner.value)
        await items.answer(Self.item(photo: "file:///a.webp", thumb: nil))
        await model.query.readTask?.value
        #expect(!model.spinner.value)
        #expect(model.phase == .photo(uri: "file:///a.webp"))
    }

    @Test("swipe down: only at zoom 1, one finger, clearly downward; closes past 80 pt")
    func gesture() {
        #expect(PhotoViewerGesture.beginsDrag(zoomScale: 1, touches: 1, dx: 0, dy: 11))
        #expect(PhotoViewerGesture.beginsDrag(zoomScale: 1.01, touches: 1, dx: 6, dy: 10.5))
        #expect(!PhotoViewerGesture.beginsDrag(zoomScale: 1, touches: 1, dx: 0, dy: 10))
        #expect(!PhotoViewerGesture.beginsDrag(zoomScale: 1.02, touches: 1, dx: 0, dy: 40))
        #expect(!PhotoViewerGesture.beginsDrag(zoomScale: 1, touches: 2, dx: 0, dy: 40))
        #expect(!PhotoViewerGesture.beginsDrag(zoomScale: 1, touches: 1, dx: 20, dy: 30))
        #expect(!PhotoViewerGesture.beginsDrag(zoomScale: 1, touches: 1, dx: 0, dy: -40))
        #expect(PhotoViewerGesture.takesDrag(zoomScale: 1, touches: 1, dx: 2, dy: 4))
        #expect(!PhotoViewerGesture.takesDrag(zoomScale: 1, touches: 1, dx: 4, dy: 4))
        #expect(PhotoViewerGesture.offset(forDrag: -12) == 0)
        #expect(PhotoViewerGesture.offset(forDrag: 30) == 30)
        #expect(!PhotoViewerGesture.closes(afterDrag: 80))
        #expect(PhotoViewerGesture.closes(afterDrag: 81))
        #expect(PhotoViewerGesture.settleMilliseconds(reduceMotion: false) == 180)
        #expect(PhotoViewerGesture.settleMilliseconds(reduceMotion: true) == 0)
    }
}

/// Items whose `getById` waits until the test answers it.
actor ItemScreensHeldReads: ItemsRepository {
    private var pending: [CheckedContinuation<ItemWithContext?, Never>] = []

    func answer(_ item: ItemWithContext?) async {
        for _ in 0..<10_000 where pending.isEmpty { await Task.yield() }
        let waiting = pending
        pending.removeAll()
        for continuation in waiting { continuation.resume(returning: item) }
    }

    func getById(_ id: String) async throws -> ItemWithContext? {
        await withCheckedContinuation { pending.append($0) }
    }

    func listByContainer(_ containerId: String) async throws -> [ItemWithContext] { [] }
    func listUnsorted() async throws -> [ItemWithContext] { [] }
    func listRecent(limit: Int) async throws -> [ItemWithContext] { [] }
    func countUnsorted() async throws -> Int { 0 }
    func create(_ draft: ItemDraft) async throws -> Item { throw EntitiesFailure("not used") }
    func update(_ id: String, _ input: UpdateItemInput) async throws -> Item? { nil }
    func getPhotos(_ itemId: String) async throws -> [ItemPhoto] { [] }
    func delete(_ id: String) async throws -> DeletionResult { .notDeleted }
    func countAll() async throws -> Int { 0 }
}
