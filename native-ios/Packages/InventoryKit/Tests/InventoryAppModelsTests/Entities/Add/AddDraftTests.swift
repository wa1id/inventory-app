import Foundation
import InventoryCore
import Testing
@testable import InventoryAppModels

/// `src/ui/add/__tests__/addDraft.test.ts` (photo deletion through a spy, as RN mocks it).
@MainActor
@Suite("addDraft (addDraft.test.ts)")
struct EntitiesAddDraftTests {
    private let photo = AddPhoto(uri: "file:///p.webp", thumbUri: "file:///p-thumb.webp")

    private func draft(name: String = "Torch", photo: AddPhoto? = nil, savedAt: Int64 = 1000) -> AddDraft {
        AddDraft(
            state: AddDraftState(
                values: ItemFormValues(name: name), placeId: DropZone.containerId, picked: nil, photo: photo, suggestion: .idle, showMore: false),
            savedAt: savedAt
        )
    }

    @Test("restores a draft for half an hour, then not")
    func halfAnHour() {
        let store = AddDraftStore(photos: EntitiesPhotoSpy())
        let kept = draft()
        store.keepDraft(owner: "a", draft: kept)
        #expect(store.restorableDraft(now: 1000 + AddDraftStore.ttlMs) == kept)
        #expect(store.restorableDraft(now: 1000 + AddDraftStore.ttlMs + 1) == nil)
    }

    @Test("deletes a stale draft’s photo, both files, and leaves a fresh one")
    func staleDeletesPhoto() {
        let photos = EntitiesPhotoSpy()
        let store = AddDraftStore(photos: photos)
        store.keepDraft(owner: "a", draft: draft(photo: photo))
        store.discardStaleDraft(now: 2000)
        #expect(photos.deleted.isEmpty)
        #expect(store.restorableDraft(now: 2000) != nil)

        store.discardStaleDraft(now: 1000 + AddDraftStore.ttlMs + 1)
        #expect(photos.deleted == [[photo.uri, photo.thumbUri]])
        #expect(store.restorableDraft(now: 1000) == nil)
    }

    @Test("deletes a replaced draft’s photo unless the new draft carries it")
    func replacedDeletesPhoto() {
        let photos = EntitiesPhotoSpy()
        let store = AddDraftStore(photos: photos)
        store.keepDraft(owner: "a", draft: draft(photo: photo))
        store.keepDraft(owner: "b", draft: draft(photo: photo))
        #expect(photos.deleted.isEmpty)

        store.keepDraft(owner: "c", draft: draft(name: "Glue"))
        #expect(photos.deleted == [[photo.uri, photo.thumbUri]])
    }

    @Test("lets only the sheet that wrote the draft clear it")
    func onlyOwnerClears() {
        let photos = EntitiesPhotoSpy()
        let store = AddDraftStore(photos: photos)
        store.keepDraft(owner: "a", draft: draft())
        store.keepDraft(owner: "b", draft: nil)
        store.clearDraft(owner: "b")
        #expect(store.restorableDraft(now: 1000) != nil)

        store.keepDraft(owner: "a", draft: nil)
        #expect(store.restorableDraft(now: 1000) == nil)

        store.keepDraft(owner: "a", draft: draft(photo: photo))
        store.clearDraft(owner: "a")
        #expect(store.restorableDraft(now: 1000) == nil)
        // After a save the item owns the photo.
        #expect(photos.deleted.isEmpty)
    }

    @Test("a draft written in the future (clock change) still counts as fresh, as in RN")
    func futureDraft() {
        #expect(AddDraftStore.isFresh(draft(savedAt: 5000), now: 1000))
        #expect(!AddDraftStore.isFresh(draft(savedAt: .min), now: .max))
    }
}
