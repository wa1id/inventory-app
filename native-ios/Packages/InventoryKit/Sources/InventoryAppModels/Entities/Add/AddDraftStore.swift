import InventoryServices

/// What the Add sheet held when it was swiped away (RN `src/ui/add/addDraft.ts`; 06 §10.6).
///
/// One draft, in memory: a sheet closed by a swipe or Back keeps what was typed, the place and
/// the photo, and the next plain open of Add within half an hour brings them back. Only the
/// header's Cancel throws a draft away (after asking). The draft owns its photo until the item
/// is saved, so a photo taken for an item nobody saved is deleted, not left on the phone. Lost
/// when the app quits, which is fine for half an hour's typing.
///
/// The app keeps one store for its whole life; each sheet writes it under its own owner id, and
/// only the sheet that wrote the draft may clear it.
@MainActor
public final class AddDraftStore {
    /// A draft older than this is thrown away on the next open, photo and all (RN `DRAFT_TTL_MS`).
    public nonisolated static let ttlMs: Int64 = 30 * 60 * 1000

    private var slot: (owner: String, draft: AddDraft)?
    private let photos: any PhotoStoring

    /// - Parameter photos: deletes a dropped draft's photo files.
    public init(photos: any PhotoStoring) {
        self.photos = photos
    }

    /// Whether `draft` may still be restored at `now` (inclusive of exactly 30 minutes)
    /// (RN `isDraftFresh`).
    public nonisolated static func isFresh(_ draft: AddDraft, now: Int64) -> Bool {
        let (age, overflow) = now.subtractingReportingOverflow(draft.savedAt)
        return !overflow && age <= ttlMs
    }

    /// The draft a plain open of Add restores, if it is fresh; no side effects
    /// (RN `restorableDraft`).
    public func restorableDraft(now: Int64) -> AddDraft? {
        guard let slot, Self.isFresh(slot.draft, now: now) else { return nil }
        return slot.draft
    }

    /// Throws away a draft older than half an hour, and its photo (RN `discardStaleDraft`).
    public func discardStaleDraft(now: Int64) {
        guard let slot, !Self.isFresh(slot.draft, now: now) else { return }
        photos.deleteStoredPhotos(AddSheet.photoFiles(slot.draft.state.photo))
        self.slot = nil
    }

    /// Keeps what `owner` holds now as the draft, replacing any other (RN `keepDraft`).
    ///
    /// A replaced draft's photo is deleted unless the new draft carries the same one. Nil, when
    /// the sheet holds nothing worth keeping, clears the draft only if this sheet wrote it, so
    /// opening Add for a container and closing it straight away leaves an earlier draft alone.
    public func keepDraft(owner: String, draft: AddDraft?) {
        guard let draft else {
            if let slot, slot.owner == owner { self.slot = nil }
            return
        }
        if let slot, !EntityText.same(slot.draft.state.photo?.uri, draft.state.photo?.uri) {
            photos.deleteStoredPhotos(AddSheet.photoFiles(slot.draft.state.photo))
        }
        slot = (owner, draft)
    }

    /// Forgets this sheet's draft without touching its photo: after a save the item owns the
    /// photo, and after a discard the sheet deleted it itself (RN `clearDraft`).
    public func clearDraft(owner: String) {
        if let slot, slot.owner == owner { self.slot = nil }
    }
}
