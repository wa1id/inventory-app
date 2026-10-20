import InventoryCore

// RN: each chip or stepper row's `useSavedQuantity` with its error toast
// (src/ui/components/ItemRow.tsx:161-168, SavedQuantityStepper.tsx:41-52; 06 §15.2, 07 §4.8).

extension AppContainer {
    /// The write-through quantity models for one list's chip or stepper rows, wired like RN's
    /// rows: writes go through ``repositories`` (local or household) with ``database`` as the
    /// invalidator and the platform's haptics, and a quantity that did not save shows the error
    /// toast naming the item ("The quantity of “Wood screws” was not saved. …",
    /// `SavedQuantityModel.notSavedMessage(itemName:kind:)`). The expanded large stepper of a
    /// chip row also shows ``SavedQuantityModel/error`` under itself, as RN did.
    ///
    /// Make one per list screen and keep it (in `@State`, or in the screen's model); call
    /// `keep(only:)` with the ids the list shows after each read.
    public func makeRowQuantityModels() -> ItemRowQuantityModels {
        let items = repositories.items
        let database = database
        let haptics = platform.haptics
        let telemetry = telemetry
        let toasts = toasts
        // The toast names the item as its row shows it now (a rename after the model was made
        // included), as RN's row read `item.name` at each render.
        let book = RowQuantityModelsReference()
        let models = ItemRowQuantityModels { item in
            let id = item.id
            let firstName = item.name
            return SavedQuantityModel(
                itemId: id,
                quantity: item.quantity,
                updatedAt: item.updatedAt,
                items: items,
                invalidator: database,
                haptics: haptics,
                telemetry: telemetry,
                onError: { kind in
                    let name = book.models?.latestName(of: id) ?? firstName
                    toasts.show(ToastOptions(message: SavedQuantityModel.notSavedMessage(itemName: name, kind: kind), tone: .error))
                }
            )
        }
        book.models = models
        return models
    }
}

/// The factory's models, held weakly by their own error toasts (no retain cycle).
@MainActor
private final class RowQuantityModelsReference {
    weak var models: ItemRowQuantityModels?
}
