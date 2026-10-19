import Foundation
import InventoryCore
import Testing
@testable import InventoryAppModels

/// `src/ui/item/__tests__/itemDetails.test.ts`.
private let entitiesDetailsItem = EntitiesFixtures.context(
    name: "Cordless drill", category: "Tools", tags: ["garage", "power"], quantity: 2, notes: nil)

@Suite("detailsSeed (itemDetails.test.ts)")
struct EntitiesDetailsSeedTests {
    @Test("turns the stored item into form values")
    func seeds() {
        #expect(
            ItemDetails.seed(entitiesDetailsItem)
                == ItemFormValues(name: "Cordless drill", category: "Tools", tags: "garage, power", quantity: "2", notes: "")
        )
    }
}

@Suite("detailsDirty (itemDetails.test.ts)")
struct EntitiesDetailsDirtyTests {
    private let seed = ItemDetails.seed(entitiesDetailsItem)

    @Test("is clean as seeded and with only spaces added")
    func clean() {
        #expect(!ItemDetails.isDirty(seed, seed: seed))
        var respaced = seed
        respaced.name = " Cordless drill "
        respaced.tags = "garage,power "
        #expect(!ItemDetails.isDirty(respaced, seed: seed))
    }

    @Test("is dirty when any field really changes")
    func dirty() {
        var name = seed
        name.name = "Drill"
        var category = seed
        category.category = ""
        var tags = seed
        tags.tags = "garage"
        var notes = seed
        notes.notes = "Charger in the bag"
        for values in [name, category, tags, notes] {
            #expect(ItemDetails.isDirty(values, seed: seed))
        }
    }

    @Test("ignores the quantity, which this form does not edit")
    func ignoresQuantity() {
        var values = seed
        values.quantity = "5"
        #expect(!ItemDetails.isDirty(values, seed: seed))
    }
}

@Suite("rebaseDetails (itemDetails.test.ts)")
struct EntitiesRebaseDetailsTests {
    private let seed = ItemDetails.seed(entitiesDetailsItem)
    private let theirs = ItemDetails.seed(
        name: "Cordless drill", category: "Tools", tags: ["garage", "power"], notes: "Charger in the bag", quantity: 3)

    @Test("keeps what was typed here and takes their change to a field left alone")
    func keepsTyped() {
        var typed = seed
        typed.category = "Power tools"
        var expected = theirs
        expected.category = "Power tools"
        #expect(ItemDetails.rebase(typed, seed: seed, theirs: theirs) == expected)
    }

    @Test("keeps what was typed when both changed the same field")
    func bothChanged() {
        var typed = seed
        typed.notes = "Battery is flat"
        #expect(ItemDetails.rebase(typed, seed: seed, theirs: theirs).notes == "Battery is flat")
    }

    @Test("counts only real changes as typed, as detailsDirty does")
    func onlyRealChanges() {
        var respaced = seed
        respaced.name = " Cordless drill "
        respaced.tags = "garage,power"
        var renamed = theirs
        renamed.name = "Drill"
        renamed.tags = "garage"
        #expect(ItemDetails.rebase(respaced, seed: seed, theirs: renamed) == renamed)
    }
}

@Suite("keepsUnnamed (itemDetails.test.ts)")
struct EntitiesKeepsUnnamedTests {
    @Test("lets an unnamed item stay unnamed")
    func staysUnnamed() {
        #expect(ItemDetails.keepsUnnamed(storedName: "", typedName: ""))
        #expect(ItemDetails.keepsUnnamed(storedName: "", typedName: "   "))
    }

    @Test("requires a name once one is typed or the item had one")
    func requiresName() {
        #expect(!ItemDetails.keepsUnnamed(storedName: "", typedName: "Batteries"))
        #expect(!ItemDetails.keepsUnnamed(storedName: "Batteries", typedName: ""))
    }
}

@Suite("itemStamp (itemDetails.test.ts)")
struct EntitiesItemStampTests {
    // Date.UTC(2026, 8, 2, 12): noon UTC reads 2 September in every zone from UTC−11 to UTC+11.
    private let created: Int64 = 1_788_350_400_000
    private let day: Int64 = 24 * 60 * 60 * 1000

    @Test("says when it was added")
    func added() {
        #expect(ItemDetails.stamp(createdAt: created, updatedAt: created + 30_000, now: created + 3 * day) == "Added 2 September 2026.")
    }

    @Test("adds the last change once it is more than a minute after adding")
    func changed() {
        #expect(
            ItemDetails.stamp(createdAt: created, updatedAt: created + day, now: created + 4 * day)
                == "Added 2 September 2026. Last changed 3 days ago."
        )
    }

    @Test("a change exactly a minute after adding is still part of adding it")
    func boundary() {
        #expect(ItemDetails.stamp(createdAt: created, updatedAt: created + 60_000, now: created + day) == "Added 2 September 2026.")
        #expect(ItemDetails.stamp(createdAt: created, updatedAt: created + 60_001, now: created + 60_001).hasSuffix("Last changed just now."))
    }
}

@Suite("attemptName (itemDetails.test.ts)")
struct EntitiesAttemptNameTests {
    private let conflict = EntitiesFakeItems.Answer<Item?>.failure(ConflictError(updatedAt: 20))

    @Test("names it with the lock it had")
    func namesWithLock() async {
        let items = EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(updatedAt: 11))])
        let outcome = await ItemDetails.attemptName(items, id: "item-1", updatedAt: 10, name: "Batteries")
        guard case .named = outcome else { Issue.record("\(outcome)"); return }
        #expect(await items.stamps == [10])
    }

    @Test("reports a null update as gone")
    func nullIsGone() async {
        let items = EntitiesFakeItems(updates: [.value(nil)])
        guard case .gone = await ItemDetails.attemptName(items, id: "item-1", updatedAt: 10, name: "Batteries") else {
            Issue.record("expected gone"); return
        }
    }

    @Test("keeps the typed name when recognition names it between load and save")
    func namedMeanwhile() async {
        // Loaded unnamed at 10; recognition then names it at 20, after the last re-read.
        let stored = EntitiesLockedStore(name: "", updatedAt: 10)
        await stored.write(name: "AA batteries", updatedAt: 20)

        // Nothing is written over the other name unasked, and the typed one is not dropped…
        let first = await ItemDetails.attemptName(stored, id: "item-1", updatedAt: 10, name: "Batteries")
        guard case .namedMeanwhile(let name, let updatedAt) = first else { Issue.record("\(first)"); return }
        #expect(name == "AA batteries")
        #expect(updatedAt == 20)
        #expect(await stored.name == "AA batteries")

        // …and saving it again, over the stamp that came back, stores it.
        guard case .named = await ItemDetails.attemptName(stored, id: "item-1", updatedAt: 20, name: "Batteries") else {
            Issue.record("expected named"); return
        }
        #expect(await stored.name == "Batteries")
        #expect(await stored.stamps == [10, 20])
    }

    @Test("saves when the name it met is the one typed")
    func metSameName() async {
        let stored = EntitiesLockedStore(name: "", updatedAt: 10)
        await stored.write(name: "Batteries", updatedAt: 20)
        guard case .named = await ItemDetails.attemptName(stored, id: "item-1", updatedAt: 10, name: "Batteries") else {
            Issue.record("expected named"); return
        }
        #expect(await stored.name == "Batteries")
        #expect(await stored.stamps == [10, 20])
    }

    @Test("retries once when something else changed")
    func retriesOnce() async {
        let items = EntitiesFakeItems(
            updates: [conflict, .value(EntitiesFixtures.item(updatedAt: 21))],
            lastRead: .value(EntitiesFixtures.context(name: "", updatedAt: 20))
        )
        guard case .named = await ItemDetails.attemptName(items, id: "item-1", updatedAt: 10, name: "Batteries") else {
            Issue.record("expected named"); return
        }
        #expect(await items.stamps == [10, 20])
    }

    @Test("fails without retrying anything but a conflict")
    func failsWithoutRetry() async {
        let cause = EntitiesFailure("offline")
        let items = EntitiesFakeItems(updates: [.failure(cause)])
        let outcome = await ItemDetails.attemptName(items, id: "item-1", updatedAt: 10, name: "Batteries")
        guard case .failed(let error) = outcome else { Issue.record("\(outcome)"); return }
        #expect(error as? EntitiesFailure == cause)
        #expect(await items.stamps == [10])
    }

    @Test("a re-read that fails, or a second conflict, fails; a different name compares by code units")
    func moreFailures() async {
        let reread = EntitiesFakeItems(updates: [conflict], lastRead: .failure(EntitiesFailure("read")))
        guard case .failed = await ItemDetails.attemptName(reread, id: "item-1", updatedAt: 10, name: "Café") else {
            Issue.record("expected failed"); return
        }
        let twice = EntitiesFakeItems(updates: [conflict, conflict], lastRead: .value(EntitiesFixtures.context(name: "", updatedAt: 20)))
        guard case .failed = await ItemDetails.attemptName(twice, id: "item-1", updatedAt: 10, name: "Café") else {
            Issue.record("expected failed"); return
        }
        // "Cafe\u{301}" is a different name to JS, although Swift's == calls them equal.
        let decomposed = EntitiesFakeItems(updates: [conflict], lastRead: .value(EntitiesFixtures.context(name: "Cafe\u{301}", updatedAt: 20)))
        guard case .namedMeanwhile = await ItemDetails.attemptName(decomposed, id: "item-1", updatedAt: 10, name: "Café") else {
            Issue.record("expected namedMeanwhile"); return
        }
    }
}

@Suite("attemptDetails (itemDetails.test.ts)")
struct EntitiesAttemptDetailsTests {
    private let conflict = EntitiesFakeItems.Answer<Item?>.failure(ConflictError(updatedAt: 20))
    private let base = ItemDetailsBase(updatedAt: 10, values: ItemDetails.seed(entitiesDetailsItem))
    private let patch = ItemDetailsPatch(name: "Drill", category: "Tools", tags: ["garage"], notes: nil)

    private func fresh(notes: String? = nil, quantity: Int = 2) -> ItemWithContext {
        EntitiesFixtures.context(name: "Cordless drill", category: "Tools", tags: ["garage", "power"], quantity: quantity, notes: notes, updatedAt: 20)
    }

    @Test("saves over the version the form was filled from")
    func saves() async {
        let items = EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(updatedAt: 11))])
        guard case .saved = await ItemDetails.attemptDetails(items, id: "item-1", patch: patch, base: base) else {
            Issue.record("expected saved"); return
        }
        #expect(await items.stamps == [10])
        let input = await items.updates.first?.input
        #expect(input?.name == "Drill")
        #expect(input?.category == .set("Tools"))
        #expect(input?.notes == .clear)
        #expect(input?.tags == ["garage"])
        #expect(input?.quantity == nil)
    }

    @Test("reports a null update as gone")
    func nullIsGone() async {
        let items = EntitiesFakeItems(updates: [.value(nil)])
        guard case .gone = await ItemDetails.attemptDetails(items, id: "item-1", patch: patch, base: base) else {
            Issue.record("expected gone"); return
        }
    }

    @Test("saves once more when only the quantity changed meanwhile")
    func onlyQuantity() async {
        let items = EntitiesFakeItems(updates: [conflict, .value(EntitiesFixtures.item(updatedAt: 21))], lastRead: .value(fresh(quantity: 3)))
        guard case .saved = await ItemDetails.attemptDetails(items, id: "item-1", patch: patch, base: base) else {
            Issue.record("expected saved"); return
        }
        #expect(await items.stamps == [10, 20])
    }

    @Test("stops at a change to these details and hands back their version")
    func conflictWithTheirs() async {
        let theirs = fresh(notes: "Charger in the bag")
        let items = EntitiesFakeItems(updates: [conflict], lastRead: .value(theirs))
        let outcome = await ItemDetails.attemptDetails(items, id: "item-1", patch: patch, base: base)
        guard case .conflict(let their) = outcome else { Issue.record("\(outcome)"); return }
        #expect(their == ItemDetailsBase(updatedAt: 20, values: ItemDetails.seed(theirs)))
        #expect(await items.stamps == [10])
    }

    @Test("treats an item deleted after the conflict as gone")
    func deletedAfterConflict() async {
        let items = EntitiesFakeItems(updates: [conflict], lastRead: .value(nil))
        guard case .gone = await ItemDetails.attemptDetails(items, id: "item-1", patch: patch, base: base) else {
            Issue.record("expected gone"); return
        }
    }

    @Test("gives up after one retry")
    func givesUp() async {
        let items = EntitiesFakeItems(updates: [conflict, conflict], lastRead: .value(fresh()))
        guard case .failed = await ItemDetails.attemptDetails(items, id: "item-1", patch: patch, base: base) else {
            Issue.record("expected failed"); return
        }
        #expect(await items.stamps == [10, 20])
    }

    @Test("fails without retrying anything but a conflict")
    func failsWithoutRetry() async {
        let cause = EntitiesFailure("offline")
        let items = EntitiesFakeItems(updates: [.failure(cause)])
        let outcome = await ItemDetails.attemptDetails(items, id: "item-1", patch: patch, base: base)
        guard case .failed(let error) = outcome else { Issue.record("\(outcome)"); return }
        #expect(error as? EntitiesFailure == cause)
        #expect(await items.stamps == [10])
    }

    @Test("an unnamed item kept unnamed leaves the name out of the write")
    func unnamedLeavesNameOut() async {
        let items = EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(updatedAt: 11))])
        let unnamed = ItemDetailsPatch(name: nil, category: nil, tags: [], notes: "spare")
        _ = await ItemDetails.attemptDetails(items, id: "item-1", patch: unnamed, base: base)
        let input = await items.updates.first?.input
        #expect(input?.name == nil)
        #expect(input?.category == .clear)
        #expect(input?.notes == .set("spare"))
        #expect(input?.tags == [])
    }
}

@Suite("item details parity (Fixtures/entities)")
struct EntitiesItemDetailsParityTests {
    struct Values: Decodable {
        let name, category, tags, quantity, notes: String
        var form: ItemFormValues { ItemFormValues(name: name, category: category, tags: tags, quantity: quantity, notes: notes) }
    }

    struct Source: Decodable {
        let name: String
        let category: String?
        let tags: [String]
        let notes: String?
        let quantity: Int
    }

    struct SeedCase: Decodable {
        let source: Source
        let expected: Values
    }

    struct DetailsCase: Decodable {
        let values: Values
        let seed: Values
        let theirs: Values
        let dirty: Bool
        let rebased: Values
    }

    struct UnnamedCase: Decodable {
        let stored: String
        let typed: String
        let expected: Bool
    }

    struct Fixture: Decodable {
        let detailsSeed: [SeedCase]
        let details: [DetailsCase]
        let keepsUnnamed: [UnnamedCase]
    }

    @Test("detailsSeed, detailsDirty, rebaseDetails and keepsUnnamed match JS")
    func matches() throws {
        let url = try #require(Bundle.module.url(forResource: "entities-vectors", withExtension: "json", subdirectory: "Fixtures/entities"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for vector in fixture.detailsSeed {
            let source = vector.source
            let seeded = ItemDetails.seed(name: source.name, category: source.category, tags: source.tags, notes: source.notes, quantity: source.quantity)
            #expect(EntitiesUnits.of(seeded) == EntitiesUnits.of(vector.expected.form))
        }
        for vector in fixture.details {
            #expect(ItemDetails.isDirty(vector.values.form, seed: vector.seed.form) == vector.dirty, "\(vector.values)")
            let rebased = ItemDetails.rebase(vector.values.form, seed: vector.seed.form, theirs: vector.theirs.form)
            #expect(EntitiesUnits.of(rebased) == EntitiesUnits.of(vector.rebased.form), "\(vector.values)")
        }
        for vector in fixture.keepsUnnamed {
            #expect(ItemDetails.keepsUnnamed(storedName: vector.stored, typedName: vector.typed) == vector.expected)
        }
    }
}
