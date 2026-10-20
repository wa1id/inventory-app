import CoreGraphics
import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage

extension AppContainer {
    /// A container for `#Preview`s and the DEBUG demo: a private in-memory database seeded with
    /// ``AppContainerPreviewData`` when `seed` is on, photos in a fresh temporary directory, an
    /// in-memory keychain and preferences, no network and no system boot steps. Like the live
    /// container it does nothing until ``boot`` runs; previews run it from a `.task`.
    ///
    /// - Parameters:
    ///   - seed: fill the database with sample spaces, containers, items and a drop-zone backlog.
    ///   - onboardingCompleted: start on the main shell instead of onboarding.
    ///   - householdSession: start joined to this household (its requests go to `transport`).
    ///   - transport: where HTTP goes; nowhere (offline) by default.
    public static func preview(
        platform: AppPlatform = .silent(),
        seed: Bool = true,
        onboardingCompleted: Bool = true,
        householdSession: HouseholdSession? = nil,
        transport: any HTTPTransport = ShellOfflineTransport()
    ) -> AppContainer {
        let root = URL.temporaryDirectory.appending(path: "inventory-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let resolver = PhotoPathResolver(
            documents: root.appending(path: "Documents", directoryHint: .isDirectory),
            caches: root.appending(path: "Library/Caches", directoryHint: .isDirectory)
        )
        let preferences = InMemoryPreferences(onboardingCompleted ? [PreferenceKey.onboardingCompleted: "true"] : [:])
        let keychain = InMemoryKeychain()
        if let householdSession { try? HouseholdSessionStore(keychain: keychain).save(householdSession) }
        return AppContainer(
            dependencies: Dependencies(
                config: AppConfig(),
                keychain: keychain,
                preferences: preferences,
                openDatabase: {
                    let store = try DatabaseStore.inMemory()
                    try await store.migrate()
                    if seed {
                        try await AppContainerPreviewData.seed(
                            LocalRepositories(store: store, environment: AppContainerPreviewData.environment),
                            photos: ImageStore(resolver: resolver)
                        )
                    }
                    return store
                },
                transport: transport,
                networkTelemetry: NetworkTelemetry(event: { _, _ in }, error: { _, _ in }),
                photoPathResolver: resolver,
                protectedData: HouseholdModel.ProtectedDataGate(isAvailable: { true }, waitUntilAvailable: {}),
                bootSystem: .inert
            ),
            platform: platform
        )
    }
}

/// Sample inventory for previews and the DEBUG demo: three spaces with containers of several
/// types (each with its short code, one with a QR label), items with and without photos, one
/// with none left, and four items waiting in the drop zone. `docs/UI-KIT.md` lists every name.
///
/// Through ``AppContainer/preview(platform:seed:onboardingCompleted:householdSession:transport:)``
/// the short codes and the label are fixed (``shortCodes``, ``toolChestLabelToken``), so
/// screenshots, demo routes and UI tests can name them; ids stay random.
public enum AppContainerPreviewData {
    /// The seeded containers' short codes, one per type (Tool chest, Red bin, the unnamed box,
    /// Pantry shelf, Top drawer, Winter clothes). Containers made later get random codes.
    public static let shortCodes: [ContainerVisualType: String] = [
        .cabinet: "CAB-J92R",
        .bin: "BIN-4F2A",
        .box: "BOX-7K2M",
        .shelf: "SHF-3PQX",
        .drawer: "DRW-8HNC",
        .bag: "BAG-5WTD",
    ]

    /// The QR label bound to the Tool chest (`inventory://c/<token>` opens it).
    public static let toolChestLabelToken = "c0ffee00c0ffee00c0ffee00c0ffee00"

    /// A well-formed label token bound to nothing (the "link this label" state).
    public static let unboundLabelToken = "0123456789abcdef0123456789abcdef"

    /// The seed's repository environment: ``shortCodes`` for the seeded types.
    public static let environment = RepositoryEnvironment(shortCode: { type in
        shortCodes[type] ?? generateShortCode(type)
    })

    /// What the seed created, for previews that open a specific record.
    public struct Seeded: Sendable {
        public var garageId: String
        public var toolChestId: String
        public var drillId: String
        public var dropZoneItemIds: [String]
    }

    /// Writes the sample inventory through `repositories`; photos are drawn and stored with
    /// `photos`. A photo that cannot be stored is left out rather than failing the seed.
    @discardableResult
    public static func seed(_ repositories: LocalRepositories, photos: any PhotoStoring) async throws -> Seeded {
        let spaces = repositories.spaces
        let containers = repositories.containers
        let items = repositories.items

        let garage = try await spaces.create(CreateSpaceInput(name: "Garage", icon: "🧰", color: "#5B8DEF"))
        let kitchen = try await spaces.create(CreateSpaceInput(name: "Kitchen", icon: "🍳", color: "#E07A5F"))
        let attic = try await spaces.create(CreateSpaceInput(name: "Attic", icon: "📦", color: "#81B29A"))

        let toolChest = try await containers.create(CreateContainerInput(spaceId: garage.id, name: "Tool chest", visualType: .cabinet))
        let redBin = try await containers.create(CreateContainerInput(spaceId: garage.id, name: "Red bin", visualType: .bin))
        let box = try await containers.create(CreateContainerInput(spaceId: garage.id, name: nil, visualType: .box))
        let pantry = try await containers.create(CreateContainerInput(spaceId: kitchen.id, name: "Pantry shelf", visualType: .shelf))
        let drawer = try await containers.create(CreateContainerInput(spaceId: kitchen.id, name: "Top drawer", visualType: .drawer))
        let winter = try await containers.create(CreateContainerInput(spaceId: attic.id, name: "Winter clothes", visualType: .bag))
        _ = try await repositories.qr.bind(token: toolChestLabelToken, containerId: toolChest.id)

        let drill = try await items.create(ItemDraft(
            containerId: toolChest.id, name: "Cordless drill", category: "Tools", quantity: 1,
            notes: "Charger is in the red bin.", tags: ["power tools"],
            photo: await photo(photos, hue: 0.58)
        ))
        _ = try await items.create(ItemDraft(containerId: toolChest.id, name: "Screwdriver set", category: "Tools"))
        _ = try await items.create(ItemDraft(containerId: redBin.id, name: "Extension cord", quantity: 2))
        _ = try await items.create(ItemDraft(containerId: box.id, name: "Christmas lights", category: "Decorations", quantity: 3))
        _ = try await items.create(ItemDraft(containerId: drawer.id, name: "AA batteries", category: "Batteries", quantity: 12))
        _ = try await items.create(ItemDraft(containerId: drawer.id, name: "Printer ink", quantity: 0))
        _ = try await items.create(ItemDraft(
            containerId: pantry.id, name: "Olive oil", category: "Food", quantity: 2,
            photo: await photo(photos, hue: 0.16)
        ))
        _ = try await items.create(ItemDraft(containerId: winter.id, name: "Wool scarf", category: "Clothes"))

        var waiting: [String] = []
        waiting.append(try await items.create(ItemDraft(containerId: DropZone.containerId, name: "HDMI cable", quantity: 2)).id)
        waiting.append(try await items.create(ItemDraft(containerId: DropZone.containerId, name: "Spare keys")).id)
        waiting.append(try await items.create(ItemDraft(
            containerId: DropZone.containerId, name: "Bike pump", photo: await photo(photos, hue: 0.33)
        )).id)
        // A Quick Snap shot nobody named yet.
        waiting.append(try await items.create(ItemDraft(
            containerId: DropZone.containerId, name: nil, photo: await photo(photos, hue: 0.92)
        )).id)

        return Seeded(garageId: garage.id, toolChestId: toolChest.id, drillId: drill.id, dropZoneItemIds: waiting)
    }

    /// A drawn photo (a soft two-tone square) stored like a capture, or nil when storing fails.
    static func photo(_ photos: any PhotoStoring, hue: Double) async -> ItemPhotoInput? {
        guard let image = drawImage(hue: hue),
              let stored = try? await photos.storeItemPhoto(.image(image), cropToAspect: nil)
        else { return nil }
        return ItemPhotoInput(
            uri: stored.uri, thumbUri: stored.thumbUri, width: stored.width, height: stored.height, byteSize: stored.byteSize)
    }

    private static func drawImage(hue: Double) -> CGImage? {
        let side = 480
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let (r, g, b) = rgb(hue: hue, saturation: 0.45, brightness: 0.85)
        context.setFillColor(red: r, green: g, blue: b, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let (r2, g2, b2) = rgb(hue: hue, saturation: 0.6, brightness: 0.55)
        context.setFillColor(red: r2, green: g2, blue: b2, alpha: 1)
        context.fillEllipse(in: CGRect(x: side / 5, y: side / 5, width: side * 3 / 5, height: side * 3 / 5))
        return context.makeImage()
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> (Double, Double, Double) {
        let sector = (hue - hue.rounded(.down)) * 6
        let index = Int(sector.rounded(.down)) % 6
        let fraction = sector - sector.rounded(.down)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch index {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}
