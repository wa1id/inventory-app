import InventoryCore
import InventoryStrings

// RN: src/ui/item/itemDetails.ts. The pure helpers behind the item screen and Edit details:
// seeding the form, telling real edits from re-spacing, rebasing after a conflict, the
// "Added … Last changed …" caption, and the two optimistic-lock writes (details and name).

/// The version of an item a details save goes over: its stamp, and its fields as the form
/// shows them (RN `DetailsBase`).
public struct ItemDetailsBase: Sendable, Hashable {
    public var updatedAt: Int64
    public var values: ItemFormValues

    public init(updatedAt: Int64, values: ItemFormValues) {
        self.updatedAt = updatedAt
        self.values = values
    }
}

/// What Edit details writes (RN `DetailsPatch`). `name` is nil while an unnamed item stays
/// unnamed, so the key is left out and the repository keeps `''`.
public struct ItemDetailsPatch: Sendable, Hashable {
    public var name: String?
    public var category: String?
    public var tags: [String]
    public var notes: String?

    public init(name: String?, category: String?, tags: [String], notes: String?) {
        self.name = name
        self.category = category
        self.tags = tags
        self.notes = notes
    }

    /// The repository input: category and notes always sent (`null` clears them).
    func input(expectedUpdatedAt: Int64) -> UpdateItemInput {
        UpdateItemInput(
            name: name,
            category: FieldUpdate(category),
            notes: FieldUpdate(notes),
            tags: tags,
            expectedUpdatedAt: expectedUpdatedAt
        )
    }
}

/// How a details save went (RN `DetailsOutcome`).
public enum ItemDetailsOutcome: Sendable {
    case saved
    /// Deleted on another phone (a household update answers 404 as nil).
    case gone
    /// Someone changed the name, category, tags or notes meanwhile; nothing was written.
    /// `base` is their version, which saving again goes over.
    case conflict(base: ItemDetailsBase)
    case failed(any Error)
}

/// How naming an unnamed item went (RN `NameOutcome`).
public enum ItemNameOutcome: Sendable {
    case named
    /// Deleted on another phone.
    case gone
    /// It was given another name first (recognition, or another phone). Nothing was written;
    /// saving again over `updatedAt` keeps the typed name.
    case namedMeanwhile(name: String, updatedAt: Int64)
    case failed(any Error)
}

/// The item screen's and Edit details' rules (RN `src/ui/item/itemDetails.ts`).
public enum ItemDetails {
    /// Changes closer than this to the creation are part of adding it (RN `CHANGED_AFTER_MS`).
    public static let changedAfterMs: Int64 = 60_000

    /// What Edit details is seeded with, once per item id (RN `detailsSeed`).
    public static func seed(name: String, category: String?, tags: [String], notes: String?, quantity: Int) -> ItemFormValues {
        ItemFormValues(
            name: name,
            category: category ?? "",
            tags: tags.joined(separator: ", "),
            // Not edited there (the stepper saves it), but validation reads it.
            quantity: String(quantity),
            notes: notes ?? ""
        )
    }

    /// ``seed(name:category:tags:notes:quantity:)`` from a stored item.
    public static func seed(_ item: ItemWithContext) -> ItemFormValues {
        seed(name: item.name, category: item.category, tags: item.tags, notes: item.notes, quantity: item.quantity)
    }

    /// The tags as a comparable list: split, trimmed, blanks dropped, joined with ","
    /// (RN `tagList`).
    static func tagKey(_ tags: String) -> String {
        ItemForm.tagList(tags).joined(separator: ",")
    }

    /// Whether the form holds a real change: a field that differs from the seed once trimmed
    /// (RN `detailsDirty`). Re-spacing the tags is not a change; quantity is not on this form.
    public static func isDirty(_ values: ItemFormValues, seed: ItemFormValues) -> Bool {
        EntityText.trimmedDiffer(values.name, seed.name)
            || EntityText.trimmedDiffer(values.category, seed.category)
            || !EntityText.same(tagKey(values.tags), tagKey(seed.tags))
            || EntityText.trimmedDiffer(values.notes, seed.notes)
    }

    /// The form after a conflict: a field changed here keeps what was typed, every field left
    /// alone takes their version, and the quantity is theirs (RN `rebaseDetails`).
    public static func rebase(_ values: ItemFormValues, seed: ItemFormValues, theirs: ItemFormValues) -> ItemFormValues {
        ItemFormValues(
            name: EntityText.trimmedDiffer(values.name, seed.name) ? values.name : theirs.name,
            category: EntityText.trimmedDiffer(values.category, seed.category) ? values.category : theirs.category,
            tags: EntityText.same(tagKey(values.tags), tagKey(seed.tags)) ? theirs.tags : values.tags,
            quantity: theirs.quantity,
            notes: EntityText.trimmedDiffer(values.notes, seed.notes) ? values.notes : theirs.notes
        )
    }

    /// Whether an unnamed item may be saved still unnamed (RN `keepsUnnamed`, the desk rule):
    /// it had no name and none was typed.
    public static func keepsUnnamed(storedName: String, typedName: String) -> Bool {
        storedName.isEmpty && typedName.jsTrimmed().isEmpty
    }

    /// Saves Edit details over the version the form was filled from (RN `attemptDetails`).
    ///
    /// On a conflict the item is re-read. A change to one of this form's fields is a real
    /// conflict and nothing is written. A change only to the quantity or the place (most
    /// often this phone's own stepper) is saved over once with the new stamp.
    public static func attemptDetails(
        _ items: any ItemsRepository,
        id: String,
        patch: ItemDetailsPatch,
        base: ItemDetailsBase
    ) async -> ItemDetailsOutcome {
        do {
            let updated = try await items.update(id, patch.input(expectedUpdatedAt: base.updatedAt))
            return updated == nil ? .gone : .saved
        } catch is ConflictError {
            // Re-read below.
        } catch {
            return .failed(error)
        }

        do {
            guard let fresh = try await items.getById(id) else { return .gone }
            let theirs = ItemDetailsBase(updatedAt: fresh.updatedAt, values: seed(fresh))
            if isDirty(theirs.values, seed: base.values) { return .conflict(base: theirs) }
            let updated = try await items.update(id, patch.input(expectedUpdatedAt: fresh.updatedAt))
            return updated == nil ? .gone : .saved
        } catch {
            return .failed(error)
        }
    }

    /// "Added 2 September 2026." plus " Last changed 3 days ago." once the last change is more
    /// than a minute after adding (RN `itemStamp`). The date is in the device time zone.
    public static func stamp(createdAt: Int64, updatedAt: Int64, now: Int64) -> String {
        let added = L10n.Item.stampAdded(date: Format.longDate(createdAt))
        let (gap, overflow) = updatedAt.subtractingReportingOverflow(createdAt)
        let changed = overflow ? updatedAt > createdAt : gap > changedAfterMs
        return changed ? "\(added) \(L10n.Item.stampChanged(ago: Format.ago(updatedAt, now: now)))" : added
    }

    /// Names an unnamed item, carrying its lock (RN `attemptName`).
    ///
    /// On a conflict the item is re-read. A different non-empty name (code units, untrimmed
    /// against the trimmed typed one) is reported and nothing is written; otherwise the name
    /// is written once more over the new stamp. At most one retry; any error there fails.
    public static func attemptName(
        _ items: any ItemsRepository,
        id: String,
        updatedAt: Int64,
        name: String
    ) async -> ItemNameOutcome {
        do {
            let updated = try await items.update(id, UpdateItemInput(name: name, expectedUpdatedAt: updatedAt))
            return updated == nil ? .gone : .named
        } catch is ConflictError {
            // Re-read below.
        } catch {
            return .failed(error)
        }

        do {
            guard let fresh = try await items.getById(id) else { return .gone }
            if !fresh.name.isEmpty && !EntityText.same(fresh.name, name) {
                return .namedMeanwhile(name: fresh.name, updatedAt: fresh.updatedAt)
            }
            let updated = try await items.update(id, UpdateItemInput(name: name, expectedUpdatedAt: fresh.updatedAt))
            return updated == nil ? .gone : .named
        } catch {
            return .failed(error)
        }
    }
}
