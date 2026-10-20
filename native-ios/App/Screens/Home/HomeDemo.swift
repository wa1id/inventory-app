#if DEBUG
import Foundation
import InventoryAppModels
import InventoryCore
import InventoryNetwork
import InventoryServices

/// DEBUG demo hooks for the home area: Home, Spaces and the Drop zone tab.
///
/// They let every state be screenshotted without tapping:
/// `mac.sh run out.png -demo YES -demoArea home -demoState <state> [-demoTab spaces|dropZone]`.
///
/// | State | What shows |
/// |---|---|
/// | `search` | "batteries" typed: Items with the totals line (AA batteries in two containers) |
/// | `searchPlaces` | "garage" typed: the summary, Spaces and containers, Kept in those places |
/// | `noResults` | "zebra" typed: "Nothing called “zebra”" with Add “zebra”… |
/// | `misspelt` | "drils" typed: corrected to "drill", with "No results for “drils”. Showing “drill” instead." |
/// | `backlog` | thirty more items waiting in the drop zone (the card, the badge, a long list) |
/// | `filed` | the drop zone emptied (Home without the card; "Everything is filed") |
/// | `noticeDismissed` | the unpaired notice put away |
/// | `empty` | no inventory, not joined: "Nothing is stored here yet" with Join and Start |
/// | `emptyLocal` | not joined, one space and nothing stored: "Add an item" |
/// | `paired` | joined to "Smith family", answered by a fake home server |
/// | `pairedEmpty` | joined to "Smith family", whose home server has nothing yet |
/// | `refreshFailed` | joined; the first reads answer, every later one fails (the stale-data banners) |
/// | `serverError` | joined; the home server answers every read with a 500 (the error states) |
/// | `reconnecting` | joined; the home server does not answer (the signal caption, "waiting") |
enum HomeDemo {
    /// The household the demo states join.
    static let householdName = "Smith family"

    /// The container to run on for `state`, or nil for the default demo container (the seeded
    /// inventory in memory, or an empty one with `-demoSeed empty`). Called before anything
    /// shows; build it with `AppContainer.preview(platform: platform, …)` so nothing on the
    /// device is touched.
    @MainActor
    static func container(state: String, platform: AppPlatform) -> AppContainer? {
        let session = HouseholdSession(
            origin: "https://box.example", token: "demo-token", deviceId: "demo-device", deviceName: "iPhone",
            householdName: householdName)
        switch state {
        case "empty", "emptyLocal":
            return AppContainer.preview(platform: platform, seed: false)
        case "paired":
            return AppContainer.preview(platform: platform, seed: false, householdSession: session, transport: HomeDemoHouseholdTransport(mode: .answers))
        case "pairedEmpty":
            return AppContainer.preview(platform: platform, seed: false, householdSession: session, transport: HomeDemoHouseholdTransport(mode: .nothingStored))
        case "refreshFailed":
            return AppContainer.preview(platform: platform, seed: false, householdSession: session, transport: HomeDemoHouseholdTransport(mode: .firstAnswersOnly))
        case "serverError":
            return AppContainer.preview(platform: platform, seed: false, householdSession: session, transport: HomeDemoHouseholdTransport(mode: .serverError))
        case "reconnecting":
            return AppContainer.preview(platform: platform, seed: false, householdSession: session, transport: HomeDemoHouseholdTransport(mode: .unreachable))
        default:
            return nil
        }
    }

    /// Runs once the main shell shows, after `-demoTab` and before `-demoRoute`: put `app` in
    /// `state` (write records through `app.repositories`, start a model, show a notice).
    @MainActor
    static func run(state: String, app: AppContainer) async {
        do {
            switch state {
            case "search":
                try await addSecondBatteries(app)
                app.home.setQuery("batteries")
            case "searchPlaces":
                app.home.setQuery("garage")
            case "noResults":
                app.home.setQuery("zebra")
            case "misspelt":
                app.home.setQuery("drils")
            case "backlog":
                try await addBacklog(app)
            case "filed":
                for item in try await app.repositories.items.listUnsorted() {
                    _ = try await app.repositories.items.delete(item.id)
                }
                app.database.invalidate()
            case "noticeDismissed":
                app.home.dismissNotice()
            case "emptyLocal":
                _ = try await app.repositories.spaces.create(CreateSpaceInput(name: "Garage", icon: "🧰", color: "#5B8DEF"))
                app.database.invalidate()
            case "refreshFailed":
                // Once the first reads have answered, every screen in front reads again and fails.
                try? await Task.sleep(for: .seconds(3))
                app.database.invalidate()
            default:
                break
            }
        } catch {
            ShellDemo.log.error("home demo \(state, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// "AA batteries" in a second container, so the search shows the totals line.
    @MainActor
    private static func addSecondBatteries(_ app: AppContainer) async throws {
        let containers = try await app.repositories.containers.listAllWithSpace()
        guard let bin = containers.first(where: { $0.container.name == "Red bin" }) else { return }
        _ = try await app.repositories.items.create(ItemDraft(containerId: bin.id, name: "AA batteries", category: "Batteries", quantity: 4))
        app.database.invalidate()
    }

    /// Thirty more items waiting, named and unnamed, with a few counts.
    @MainActor
    private static func addBacklog(_ app: AppContainer) async throws {
        let names = ["Tent pegs", "Phone charger", "Spare bulbs", "Garden gloves", "Sticky notes", "USB stick", "Paint brush", "Bike lights", "Picture hooks", "Sellotape"]
        for index in 0..<30 {
            let name: String? = index % 4 == 3 ? nil : names[index % names.count]
            _ = try await app.repositories.items.create(ItemDraft(containerId: DropZone.containerId, name: name, quantity: index % 5 == 0 ? 3 : 1))
        }
        app.database.invalidate()
    }
}

/// A home server for the paired demo states, answering from a small fixed household.
struct HomeDemoHouseholdTransport: HTTPTransport {
    enum Mode: Sendable {
        /// Every read answers.
        case answers
        /// The household has nothing stored yet.
        case nothingStored
        /// Reads answer for the first 2.5 s after the first request, then fail with a 500.
        case firstAnswersOnly
        /// The server is up (health answers) but every read fails with a 500.
        case serverError
        /// Nothing answers (the connection banner, "waiting for the home server").
        case unreachable
    }

    let mode: Mode
    private let window = HomeDemoAnswerWindow()

    init(mode: Mode) {
        self.mode = mode
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await Task.sleep(for: .milliseconds(300))
        let path = request.url?.path ?? ""
        let query = request.url?.query ?? ""
        if mode == .unreachable { throw URLError(.cannotConnectToHost) }
        if path == "/v1/health" { return Self.json(#"{"ok":true,"contractVersion":1}"#) }
        switch mode {
        case .serverError:
            return HTTPResponse(status: 500, headers: ["content-type": "application/json"], body: Data(#"{"error":"server_error"}"#.utf8))
        case .firstAnswersOnly:
            if await window.isOpen() == false {
                return HTTPResponse(status: 500, headers: ["content-type": "application/json"], body: Data(#"{"error":"server_error"}"#.utf8))
            }
        default:
            break
        }
        let household = mode == .nothingStored ? HomeDemoHousehold.empty : HomeDemoHousehold.sample
        switch path {
        case "/v1/spaces":
            return try Self.json(["spaces": household.spaces])
        case "/v1/containers":
            return try Self.json(["containers": household.containers])
        case "/v1/items":
            if query.contains("unsorted=1") { return try Self.json(["items": household.waiting]) }
            return try Self.json(["items": household.recent])
        case "/v1/search":
            return Self.json(#"{"terms":[],"locations":[],"items":[]}"#)
        default:
            return HTTPResponse(status: 404, headers: ["content-type": "application/json"], body: Data(#"{"error":"not_found"}"#.utf8))
        }
    }

    private static func json(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(text.utf8))
    }

    private static func json<Value: Encodable>(_ value: Value) throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: try JSONEncoder().encode(value))
    }
}

/// The flaky demo server answers for a while after its first request, then fails.
private actor HomeDemoAnswerWindow {
    private var opened: ContinuousClock.Instant?

    /// True within 2.5 s of the first request.
    func isOpen() -> Bool {
        let now = ContinuousClock.now
        if opened == nil { opened = now }
        return now - (opened ?? now) < .milliseconds(2500)
    }
}

/// The paired demo's household.
private struct HomeDemoHousehold: Sendable {
    var spaces: [SpaceWithCounts]
    var containers: [ContainerWithSpace]
    var recent: [ItemWithContext]
    var waiting: [ItemWithContext]

    static let empty = HomeDemoHousehold(spaces: [], containers: [], recent: [], waiting: [])

    static let sample: HomeDemoHousehold = {
        let garage = Space(id: "s-garage", name: "Garage", icon: "🧰", color: "#5B8DEF", createdAt: 1, updatedAt: 1)
        let kitchen = Space(id: "s-kitchen", name: "Kitchen", icon: "🍳", color: "#E07A5F", createdAt: 2, updatedAt: 2)
        let shelf = Container(id: "c-shelf", spaceId: garage.id, name: "Paint shelf", visualType: .shelf, shortCode: "SHF-2KQ8", createdAt: 3, updatedAt: 3)
        let drawer = Container(id: "c-drawer", spaceId: kitchen.id, name: "Cutlery drawer", visualType: .drawer, shortCode: "DRW-5MXT", createdAt: 4, updatedAt: 4)
        func item(_ id: String, _ name: String, in container: Container?, space: Space?, quantity: Int = 1, at time: Int64) -> ItemWithContext {
            ItemWithContext(
                item: Item(id: id, containerId: container?.id ?? DropZone.containerId, name: name, category: nil, quantity: quantity, notes: nil, createdAt: time, updatedAt: time),
                photoId: nil, photoUri: nil, photoThumbUri: nil, tags: [],
                spaceId: space?.id ?? DropZone.spaceId, spaceName: space?.name ?? "Drop zone", spaceIcon: space?.icon ?? "", spaceColor: space?.color ?? "",
                containerName: container?.name, containerShortCode: container?.shortCode ?? "")
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let recent = [
            item("i-tape", "Masking tape", in: shelf, space: garage, quantity: 3, at: now - 60_000),
            item("i-roller", "Paint roller", in: shelf, space: garage, at: now - 3_600_000),
            item("i-spoons", "Teaspoons", in: drawer, space: kitchen, quantity: 8, at: now - 86_400_000),
        ]
        let waiting = [item("i-lamp", "Desk lamp", in: nil, space: nil, at: now - 120_000)]
        return HomeDemoHousehold(
            spaces: [
                SpaceWithCounts(space: garage, containerCount: 1, itemCount: 2),
                SpaceWithCounts(space: kitchen, containerCount: 1, itemCount: 1),
            ],
            containers: [
                ContainerWithSpace(container: shelf, spaceName: garage.name, itemCount: 2),
                ContainerWithSpace(container: drawer, spaceName: kitchen.name, itemCount: 1),
            ],
            recent: waiting + recent,
            waiting: waiting
        )
    }()
}
#endif
