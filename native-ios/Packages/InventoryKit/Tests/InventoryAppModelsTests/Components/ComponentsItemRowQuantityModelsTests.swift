import Foundation
import InventoryCore
import Testing
@testable import InventoryAppModels

/// The rows' quantity models live with the screen, one per item id, so a write and its error
/// outlive a row that scrolls away (RN rows owned `useSavedQuantity`).
@MainActor
@Suite("Components item row quantity models")
struct ComponentsItemRowQuantityModelsTests {
    @MainActor
    final class MadeLog {
        var ids: [String] = []
    }

    private static func store(
        items: EntitiesFakeItems = EntitiesFakeItems(),
        made: @escaping @MainActor (String) -> Void = { _ in }
    ) -> ItemRowQuantityModels {
        let invalidations = SharedSeamsInvalidationCounter()
        return ItemRowQuantityModels { item in
            made(item.id)
            return SavedQuantityModel(
                itemId: item.id,
                quantity: item.quantity,
                updatedAt: item.updatedAt,
                items: items,
                invalidator: invalidations,
                haptics: { _ in }
            )
        }
    }

    @Test("the same item gets the same model on every ask, made once")
    func oneModelPerItem() async {
        let made = MadeLog()
        let items = EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(id: "a", quantity: 4, updatedAt: 101))])
        let store = Self.store(items: items) { made.ids.append($0) }
        let first = store.model(for: EntitiesFixtures.context(id: "a", quantity: 3))
        first.setQuantity(4)
        await first.flushTask?.value
        // A re-read brings the item back with other values: still the same model, still at 4.
        let again = store.model(for: EntitiesFixtures.context(id: "a", quantity: 9))
        #expect(again === first)
        #expect(again.quantity == 4)
        _ = store.model(for: EntitiesFixtures.context(id: "b"))
        #expect(made.ids == ["a", "b"])
        #expect(store.count == 2)
    }

    @Test("items the list no longer shows are forgotten; a later ask makes a fresh model")
    func keepsOnlyShown() {
        let store = Self.store()
        let gone = store.model(for: EntitiesFixtures.context(id: "a", quantity: 3))
        _ = store.model(for: EntitiesFixtures.context(id: "b"))
        store.keep(only: ["b"])
        #expect(store.count == 1)
        let fresh = store.model(for: EntitiesFixtures.context(id: "a", quantity: 7))
        #expect(fresh !== gone)
        #expect(fresh.quantity == 7)
    }
}
