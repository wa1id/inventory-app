#if DEBUG
import Foundation
import InventoryAppModels
import InventoryCore
import Synchronization

/// DEBUG demo hooks for the places area: space and container screens and their forms.
///
/// They let every state be screenshotted without tapping:
/// `mac.sh run out.png -demo YES -demoArea places -demoState <state> [-demoRoute <spec>]`.
///
/// | State | What it does | Route to open with it |
/// |---|---|---|
/// | `many` | adds the space Workshop with 14 containers, and Parts drawer (in Workshop) with 24 items | `space:Workshop`, `container:Parts_drawer` |
/// | `empty` | adds the space Shed with no containers, and Spare crate (in Garage) with nothing in it | `space:Shed`, `container:Spare_crate` |
/// | `filled` | the next places form opens with its fields filled in | any form |
/// | `errors` | the next space form is saved with a blank name ("Give the space a name.") | `spaceNew`, `spaceEdit:Garage` |
/// | `saveProblem` | writes fail as offline, and the next form is filled in and saved once (the notice) | any form |
/// | `saveGone` | updates find the record gone, and the next edit form saves once (the gone notice) | `spaceEdit:…`, `containerEdit:…` |
/// | `deleteConfirm` | the next edit form presses Delete (the confirm shows) | `spaceEdit:…`, `containerEdit:…` |
/// | `refreshProblem` | a space or container screen's reads work once, then fail; 4 s in, a refresh shows the banner | `space:Garage`, `container:Tool_chest` (`RUN_SETTLE_SECONDS=10`) |
/// | `goneSpace`, `goneContainer` | pushes a space or container that does not exist | none |
///
/// Forms with no state open empty or seeded: `spaceNew`, `containerNew:Garage`, `spaceEdit:Garage`,
/// `containerEdit:Tool_chest`; the drop zone's are locked (`containerEdit:Drop_zone`).
enum PlacesDemo {
    /// What the next places form or screen does once it shows.
    enum Script: String {
        case filled, errors, saveProblem, saveGone, deleteConfirm, refreshProblem
    }

    /// Set by ``run(state:app:)``; read by every places form as it is made.
    @MainActor private static var script: Script?

    /// The container to run on for `state`: always the default demo container.
    @MainActor
    static func container(state: String, platform: AppPlatform) -> AppContainer? {
        nil
    }

    /// Runs once the main shell shows, after `-demoTab` and before `-demoRoute`.
    @MainActor
    static func run(state: String, app: AppContainer) async {
        switch state {
        case "many":
            await addMany(app)
        case "empty":
            await addEmpty(app)
        case "goneSpace":
            app.router.push(.space(id: "deleted-elsewhere"))
        case "goneContainer":
            app.router.push(.container(id: "deleted-elsewhere"))
        default:
            if let script = Script(rawValue: state) {
                self.script = script
                if script == .refreshProblem {
                    // Once the route has opened, a write elsewhere makes the screen read again.
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        app.database.invalidate()
                    }
                }
            } else if !state.isEmpty {
                ShellDemo.log.error("-demoState \(state, privacy: .public) is not a places state")
            }
        }
    }

    // MARK: Records

    @MainActor
    private static func addMany(_ app: AppContainer) async {
        let repositories = app.repositories
        do {
            let workshop = try await repositories.spaces.create(CreateSpaceInput(name: "Workshop", icon: "🧰", color: "#E4572E"))
            let names: [(String?, ContainerVisualType)] = [
                ("Parts drawer", .drawer), ("Paint shelf", .shelf), (nil, .box), ("Sanding kit", .bag),
                ("Offcuts", .crate), ("Clamps", .bin), ("Router bits", .drawer), (nil, .bin),
                ("Glue and tape", .box), ("Safety gear", .cabinet), ("Screws, small", .drawer),
                ("Screws, large", .drawer), ("Dust bags", .bag), ("Spare blades", .other),
            ]
            var drawer: Container?
            for (name, type) in names {
                let container = try await repositories.containers.create(CreateContainerInput(spaceId: workshop.id, name: name, visualType: type))
                if name == "Parts drawer" { drawer = container }
            }
            if let drawer {
                let items = [
                    "Wood screws", "Washers", "Hex nuts", "Wall plugs", "Cable ties", "Hinges", "Drawer runners",
                    "Picture hooks", "Spring clips", "Brass knobs", "Felt pads", "L-brackets", "Rivets", "Grommets",
                    "Magnets", "Eye bolts", "Wing nuts", "Shelf pins", "Corner braces", "Tacks", "Split pins",
                    "Velcro strips", "Spare fuses", "",
                ]
                for (index, name) in items.enumerated() {
                    _ = try await repositories.items.create(ItemDraft(
                        containerId: drawer.id,
                        name: name.isEmpty ? nil : name,
                        category: index.isMultiple(of: 3) ? "Hardware" : nil,
                        quantity: index % 5 == 0 ? 0 : index + 1
                    ))
                }
            }
        } catch {
            ShellDemo.log.error("places demo: could not add the Workshop")
        }
        app.database.invalidate()
    }

    @MainActor
    private static func addEmpty(_ app: AppContainer) async {
        let repositories = app.repositories
        do {
            _ = try await repositories.spaces.create(CreateSpaceInput(name: "Shed", icon: "🪴", color: "#2E9E4F"))
            if let garage = try await repositories.spaces.listWithCounts().first(where: { $0.name == "Garage" }) {
                _ = try await repositories.containers.create(CreateContainerInput(spaceId: garage.id, name: "Spare crate", visualType: .crate))
            }
        } catch {
            ShellDemo.log.error("places demo: could not add the empty records")
        }
        app.database.invalidate()
    }

    // MARK: Forms

    @MainActor
    static func prepare(_ model: SpaceNewModel) {
        guard let script else { return }
        let filled = SpaceFormValues(name: "Hallway", icon: "🪴", color: "#2E9E4F")
        switch script {
        case .filled:
            model.change(filled)
        case .errors:
            Task { await model.createCustom() }
        case .saveProblem:
            model.change(filled)
            Task { await model.createCustom() }
        case .saveGone, .deleteConfirm, .refreshProblem:
            break
        }
    }

    @MainActor
    static func prepare(_ model: SpaceEditModel) {
        guard let script else { return }
        Task {
            guard await seeded({ model.stored != nil }) else { return }
            var values = model.values
            switch script {
            case .filled:
                values.name = "Garage and bikes"
                values.color = "#0F9BB0"
                model.change(values)
            case .errors:
                values.name = ""
                model.change(values)
                await model.save()
            case .saveProblem, .saveGone:
                values.name = "Garage and bikes"
                model.change(values)
                await model.save()
            case .deleteConfirm:
                await model.delete()
            case .refreshProblem:
                break
            }
        }
    }

    @MainActor
    static func prepare(_ model: ContainerNewModel) {
        guard let script else { return }
        switch script {
        case .filled, .errors:
            model.setVisualType(.crate)
            model.setName("Paint tins")
        case .saveProblem:
            model.setVisualType(.crate)
            model.setName("Paint tins")
            Task { await model.save() }
        case .saveGone, .deleteConfirm, .refreshProblem:
            break
        }
    }

    @MainActor
    static func prepare(_ model: ContainerEditModel) {
        guard let script else { return }
        Task {
            guard await seeded({ model.stored != nil }) else { return }
            switch script {
            case .filled, .errors:
                model.setName("Tool chest (red)")
                model.setVisualType(.crate)
            case .saveProblem, .saveGone:
                model.setName("Tool chest (red)")
                await model.save()
            case .deleteConfirm:
                await model.delete()
            case .refreshProblem:
                break
            }
        }
    }

    /// Waits (up to 5 s) until an edit form has its record.
    @MainActor
    private static func seeded(_ ready: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if ready() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    // MARK: Failing reads and writes

    /// The spaces the places screens read and write through: failing ones while a saving or
    /// refresh problem is shown.
    @MainActor
    static func spaces(_ base: CurrentSpacesRepository) -> any SpacesRepository {
        failure.map { PlacesDemoSpaces(base: base, failure: $0, reads: readLog) } ?? base
    }

    /// The containers the places screens read and write through.
    @MainActor
    static func containers(_ base: CurrentContainersRepository) -> any ContainersRepository {
        failure.map { PlacesDemoContainers(base: base, failure: $0, reads: readLog) } ?? base
    }

    /// The items the container screen reads.
    @MainActor
    static func items(_ base: CurrentItemsRepository) -> any ItemsRepository {
        failure == .refresh ? PlacesDemoItems(base: base, reads: readLog) : base
    }

    @MainActor
    private static var failure: PlacesDemoFailure? {
        switch script {
        case .saveProblem: .offline
        case .saveGone: .gone
        case .refreshProblem: .refresh
        default: nil
        }
    }

    private static let readLog = PlacesDemoReadLog()
}

/// How the demo's reads and writes fail.
enum PlacesDemoFailure: Sendable {
    /// Writes: the home server did not answer.
    case offline
    /// Updates find the record deleted elsewhere (nil); other writes go through.
    case gone
    /// A screen's reads work the first time and fail after (a local failure, so the refresh
    /// banner shows).
    case refresh

    static let offlineError = HouseholdHttpError(status: 0, code: "offline")
}

/// A read that failed after the first.
struct PlacesDemoReadFailure: Error {}

/// Which reads already happened once, for `PlacesDemoFailure.refresh`.
final class PlacesDemoReadLog: Sendable {
    private let seen = Mutex<Set<String>>([])

    /// Throws for every read of `key` after the first.
    func check(_ key: String) throws {
        let first = seen.withLock { $0.insert(key).inserted }
        if !first { throw PlacesDemoReadFailure() }
    }
}

/// Spaces whose reads or writes fail as the demo asks.
struct PlacesDemoSpaces: SpacesRepository {
    let base: CurrentSpacesRepository
    let failure: PlacesDemoFailure
    let reads: PlacesDemoReadLog

    func listWithCounts() async throws -> [SpaceWithCounts] { try await base.listWithCounts() }
    func deletionImpact(_ id: String) async throws -> SpaceDeletionImpact { try await base.deletionImpact(id) }

    func getById(_ id: String) async throws -> Space? {
        if failure == .refresh { try reads.check("space:\(id)") }
        return try await base.getById(id)
    }

    func create(_ input: CreateSpaceInput) async throws -> Space {
        if failure == .offline { throw PlacesDemoFailure.offlineError }
        return try await base.create(input)
    }

    func update(_ id: String, _ input: UpdateSpaceInput) async throws -> Space? {
        switch failure {
        case .offline: throw PlacesDemoFailure.offlineError
        case .gone: return nil
        case .refresh: return try await base.update(id, input)
        }
    }

    func delete(_ id: String) async throws -> DeletionResult {
        if failure == .offline { throw PlacesDemoFailure.offlineError }
        return try await base.delete(id)
    }
}

/// Containers whose reads or writes fail as the demo asks.
struct PlacesDemoContainers: ContainersRepository {
    let base: CurrentContainersRepository
    let failure: PlacesDemoFailure
    let reads: PlacesDemoReadLog

    func getById(_ id: String) async throws -> Container? { try await base.getById(id) }
    func deletionImpact(_ id: String) async throws -> ContainerDeletionImpact { try await base.deletionImpact(id) }
    func listAllWithSpace() async throws -> [ContainerWithSpace] { try await base.listAllWithSpace() }

    func listBySpace(_ spaceId: String) async throws -> [ContainerWithCounts] {
        if failure == .refresh { try reads.check("containers-of:\(spaceId)") }
        return try await base.listBySpace(spaceId)
    }

    func getWithCounts(_ id: String) async throws -> ContainerWithCounts? {
        if failure == .refresh { try reads.check("container:\(id)") }
        return try await base.getWithCounts(id)
    }

    func create(_ input: CreateContainerInput) async throws -> Container {
        if failure == .offline { throw PlacesDemoFailure.offlineError }
        return try await base.create(input)
    }

    func update(_ id: String, _ input: UpdateContainerInput) async throws -> Container? {
        switch failure {
        case .offline: throw PlacesDemoFailure.offlineError
        case .gone: return nil
        case .refresh: return try await base.update(id, input)
        }
    }

    func delete(_ id: String) async throws -> DeletionResult {
        if failure == .offline { throw PlacesDemoFailure.offlineError }
        return try await base.delete(id)
    }
}

/// Items whose container reads work once, then fail.
struct PlacesDemoItems: ItemsRepository {
    let base: CurrentItemsRepository
    let reads: PlacesDemoReadLog

    func listByContainer(_ containerId: String) async throws -> [ItemWithContext] {
        try reads.check("items-of:\(containerId)")
        return try await base.listByContainer(containerId)
    }

    func listUnsorted() async throws -> [ItemWithContext] { try await base.listUnsorted() }
    func listRecent(limit: Int) async throws -> [ItemWithContext] { try await base.listRecent(limit: limit) }
    func countUnsorted() async throws -> Int { try await base.countUnsorted() }
    func getById(_ id: String) async throws -> ItemWithContext? { try await base.getById(id) }
    func create(_ draft: ItemDraft) async throws -> Item { try await base.create(draft) }
    func update(_ id: String, _ input: UpdateItemInput) async throws -> Item? { try await base.update(id, input) }
    func getPhotos(_ itemId: String) async throws -> [ItemPhoto] { try await base.getPhotos(itemId) }
    func delete(_ id: String) async throws -> DeletionResult { try await base.delete(id) }
    func countAll() async throws -> Int { try await base.countAll() }
}
#endif
