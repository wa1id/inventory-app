import Testing
@testable import InventoryServices

@Test func moduleLinks() {
    #expect(String(describing: InventoryServices.self) == "InventoryServices")
}
