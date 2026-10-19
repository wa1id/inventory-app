import SwiftUI
import InventoryCore

@main
struct InventoryApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let gallery = DebugGallery.requested {
                DebugGallery.view(named: gallery)
            } else {
                placeholder
            }
            #else
            placeholder
            #endif
        }
    }

    private var placeholder: some View {
        ContentUnavailableView("Inventory", systemImage: "shippingbox")
    }
}
