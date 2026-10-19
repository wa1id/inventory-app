#if DEBUG
import SwiftUI
import UIKit
import InventoryAppModels
import InventoryCore
import InventoryStorage

/// Sample data for the components' previews, the gallery and the app-hosted tests.
@MainActor
enum ComponentsFixtures {
    static let now = epochMillis()
    static let minute: Int64 = 60_000

    static let garage = Space(id: "s-garage", name: "Garage", icon: "🚗", color: "#5B8DEF", createdAt: 0, updatedAt: 0)
    static let kitchen = Space(id: "s-kitchen", name: "Kitchen", icon: "🍳", color: "#E4572E", createdAt: 0, updatedAt: 0)
    static let loft = Space(id: "s-loft", name: "Loft with a very long name over the stairs", icon: "", color: "#E0A800", createdAt: 0, updatedAt: 0)

    static let spaces = [
        SpaceWithCounts(space: garage, containerCount: 3, itemCount: 12),
        SpaceWithCounts(space: kitchen, containerCount: 1, itemCount: 0),
        SpaceWithCounts(space: loft, containerCount: 0, itemCount: 0),
    ]

    static let containers = [
        ContainerWithSpace(
            container: Container(id: "c-chest", spaceId: garage.id, name: "Tool chest", visualType: .cabinet, shortCode: "CAB-J92R", createdAt: 0, updatedAt: 0),
            spaceName: garage.name,
            itemCount: 7
        ),
        ContainerWithSpace(
            container: Container(id: "c-bin", spaceId: garage.id, name: nil, visualType: .bin, shortCode: "BIN-4F2A", createdAt: 0, updatedAt: 0),
            spaceName: garage.name,
            itemCount: 4
        ),
        ContainerWithSpace(
            container: Container(id: "c-drawer", spaceId: garage.id, name: "Screws and nails", visualType: .drawer, shortCode: "DRW-7K2M", createdAt: 0, updatedAt: 0),
            spaceName: garage.name,
            itemCount: 1
        ),
        ContainerWithSpace(
            container: Container(id: "c-shelf", spaceId: kitchen.id, name: "Spice shelf", visualType: .shelf, shortCode: "SHF-9QWE", createdAt: 0, updatedAt: 0),
            spaceName: kitchen.name,
            itemCount: 0
        ),
    ]

    static var options: [PlaceOption] { joinPlaceOptions(containers, spaces: spaces) }

    static func item(
        id: String,
        name: String,
        quantity: Int = 1,
        category: String? = nil,
        container: ContainerWithSpace? = containers.first,
        space: Space = garage,
        agoMinutes: Int64 = 5,
        photo: String? = nil
    ) -> ItemWithContext {
        let inDropZone = container == nil
        return ItemWithContext(
            item: Item(
                id: id,
                containerId: container?.id ?? DropZone.containerId,
                name: name,
                category: category,
                quantity: quantity,
                notes: nil,
                createdAt: now - agoMinutes * minute,
                updatedAt: now
            ),
            photoId: photo == nil ? nil : "p-\(id)",
            photoUri: photo,
            photoThumbUri: nil,
            tags: [],
            spaceId: inDropZone ? DropZone.spaceId : space.id,
            spaceName: inDropZone ? "Drop zone" : space.name,
            spaceIcon: inDropZone ? "📥" : space.icon,
            spaceColor: inDropZone ? "#0F9BB0" : space.color,
            containerName: inDropZone ? "Drop zone" : container?.name,
            containerShortCode: container?.shortCode ?? "DROP-ZONE"
        )
    }

    static let drill = item(id: "i-drill", name: "Cordless drill", quantity: 1, category: "Tools")
    static let screws = item(id: "i-screws", name: "Wood screws 4 × 40 mm", quantity: 120, category: "Hardware", container: containers[2])
    static let batteries = item(id: "i-batteries", name: "Spare batteries AA", quantity: 0, category: "Electrics", container: containers[1])
    static let unnamed = item(id: "i-unnamed", name: "", quantity: 3, container: nil, agoMinutes: 0)
    static let waiting = item(id: "i-waiting", name: "Bike pump", quantity: 2, container: nil, agoMinutes: 60 * 26)

    static let filedPlace = RowPlace(drill)
    static let dropZonePlace = RowPlace(unnamed)

    /// A saved-quantity model over an in-memory item, optionally failing every write.
    static func quantityModel(for item: ItemWithContext, failing: Bool = false) -> SavedQuantityModel {
        SavedQuantityModel(
            itemId: item.id,
            quantity: item.quantity,
            updatedAt: item.updatedAt,
            items: ComponentsGalleryItems(item: item, failing: failing),
            invalidator: ComponentsGalleryInvalidator(),
            haptics: { _ in }
        )
    }

    /// A photo written once to `Documents/item-photos/`, stored the way the app stores them.
    static func samplePhotoURI(resolver: PhotoPathResolver = PhotoPathResolver()) -> String {
        let name = "components-gallery-sample.png"
        let url = resolver.itemPhotosDirectory.appending(path: name, directoryHint: .notDirectory)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: resolver.itemPhotosDirectory, withIntermediateDirectories: true)
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                return format
            }())
            let data = renderer.pngData { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
                UIColor.systemOrange.setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 180, y: 80, width: 240, height: 240))
            }
            try? data.write(to: url)
        }
        return resolver.storedURI(forPhotoNamed: name)
    }
}

/// An in-memory items repository for the gallery's quantity models.
actor ComponentsGalleryItems: ItemsRepository {
    private var item: ItemWithContext
    private let failing: Bool

    init(item: ItemWithContext, failing: Bool) {
        self.item = item
        self.failing = failing
    }

    func update(_ id: String, _ input: UpdateItemInput) async throws -> Item? {
        if failing { throw CocoaError(.fileWriteUnknown) }
        if let quantity = input.quantity { item.item.quantity = quantity }
        item.item.updatedAt += 1
        return item.item
    }

    func getById(_ id: String) async throws -> ItemWithContext? { item }
    func listByContainer(_ containerId: String) async throws -> [ItemWithContext] { [item] }
    func listUnsorted() async throws -> [ItemWithContext] { [] }
    func listRecent(limit: Int) async throws -> [ItemWithContext] { [item] }
    func countUnsorted() async throws -> Int { 0 }
    func create(_ draft: ItemDraft) async throws -> Item { item.item }
    func getPhotos(_ itemId: String) async throws -> [ItemPhoto] { [] }
    func delete(_ id: String) async throws -> DeletionResult { DeletionResult(deleted: true, orphanedPhotoUris: []) }
    func countAll() async throws -> Int { 1 }
}

@MainActor
final class ComponentsGalleryInvalidator: InventoryInvalidating {
    func invalidate() {}
}
#endif
