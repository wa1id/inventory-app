import Testing
import InventoryStrings

/// The public API qualifies with the module name, so another module's `Format`
/// can be told apart. A type named `InventoryStrings` would shadow the module.
@Test func moduleLinks() {
    #expect(InventoryStrings.L10n.Common.cancel == "Cancel")
    #expect(InventoryStrings.Format.plural(2, "item", "items") == "2 items")
}
