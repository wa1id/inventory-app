import Testing
@testable import InventoryStrings

@Test func moduleLinks() {
    #expect(String(describing: InventoryStrings.self) == "InventoryStrings")
}
