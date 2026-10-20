import InventoryCore

// RN: each chip or stepper row owned its `useSavedQuantity` hook (src/ui/components/ItemRow.tsx,
// SavedQuantityStepper.tsx). SwiftUI rows are values that come and go as a list scrolls, so a
// screen keeps the models here, one per item id, and hands each row its own.

/// The write-through quantity models of a list's rows, one per item id (06 §15.2, 07 §4.8).
///
/// A row asks for its model while it draws (``model(for:)``): the first ask makes one, every
/// later ask, after a re-read or a scroll, gets the same, so a write in flight and its error
/// survive the row leaving the screen. The row keeps the model current with the item's
/// quantity and stamp (`ItemRow` does). ``keep(only:)`` forgets the items a list no longer
/// shows; a model mid-write finishes its write on its own.
@MainActor
public final class ItemRowQuantityModels {
    /// Makes the model for an item that has none yet (repositories, haptics and the error toast
    /// naming the item are the screen's).
    public typealias Make = @MainActor (ItemWithContext) -> SavedQuantityModel

    private let make: Make
    private var models: [String: SavedQuantityModel] = [:]

    public init(make: @escaping Make) {
        self.make = make
    }

    /// The item's model, made on the first ask.
    public func model(for item: ItemWithContext) -> SavedQuantityModel {
        if let model = models[item.id] { return model }
        let model = make(item)
        models[item.id] = model
        return model
    }

    /// Forgets every model whose item is not among `ids` (the rows the list shows now).
    public func keep(only ids: some Sequence<String>) {
        let kept = Set(ids)
        models = models.filter { kept.contains($0.key) }
    }

    /// How many models are held (for tests).
    public var count: Int { models.count }
}
