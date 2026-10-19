import Testing
@testable import InventoryStorage

@Test func moduleLinks() {
    #expect(String(describing: InventoryStorage.self) == "InventoryStorage")
}
