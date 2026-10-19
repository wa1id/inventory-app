import SwiftUI
import InventoryCore

@main
struct InventoryApp: App {
    var body: some Scene {
        WindowGroup {
            ContentUnavailableView("Inventory", systemImage: "shippingbox")
        }
    }
}
