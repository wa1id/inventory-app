import Testing
@testable import InventoryCore

@Test func moduleLinks() {
    #expect(String(describing: InventoryCore.self) == "InventoryCore")
}
