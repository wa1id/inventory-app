#if DEBUG
import Foundation
import OSLog
import SwiftUI
import UIKit
import InventoryAppModels
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage

/// DEBUG demo hooks for the add area: the Add sheet in each of its states, without tapping.
///
/// `mac.sh run out.png -demo YES -demoArea add -demoState <state>`, where `<state>` is one of
/// ``State`` (`RUN_SETTLE_SECONDS=8` for the photo and driven states):
///
/// | State | Shows |
/// |---|---|
/// | `empty` | a plain open: the drop zone selected, the name focused |
/// | `into` | opened for the Tool chest with "Drill bits" from search |
/// | `loading` | a photo, recognition still running |
/// | `offered` | a photo, the suggestion applied (name, category and tags filled, details open) |
/// | `details` | `offered`, scrolled down to the details it filled and "Snap several at once…" |
/// | `failed` | a photo, recognition refused (rate limited) with "Try suggestions again" |
/// | `stale` | a photo, the typed title no longer matching the suggestion, with "Update the other details" |
/// | `refreshed` | `stale`, then "Update the other details" answered |
/// | `place` | the place step ("Where does it go?") |
/// | `saveProblem` | a save into a container deleted under the sheet: the save problem notice |
/// | `savedNext` | "Save and add another" without a photo: "Saved. Add the next one." |
/// | `draft` | a draft left from earlier, restored with its banner |
///
/// The photo states run on a container whose recognition answers from ``AddDemoRecognitionTransport``
/// (no network). `-demoHousehold offline -demoArea add -demoState saveProblem` shows the
/// offline save problem under the "could not be loaded" banner instead.
enum AddDemo {
    enum State: String, CaseIterable {
        case empty, into, loading, offered, details, failed, stale, refreshed, place, saveProblem, savedNext, draft

        /// How the demo's recognition answers; nil keeps the default container.
        var recognition: AddDemoRecognitionTransport.Answer? {
            switch self {
            case .loading: .hold
            case .offered, .details, .stale, .refreshed: .suggestion
            case .failed: .rateLimited
            default: nil
            }
        }
    }

    static let log = Logger(subsystem: "com.wystudio.inventory", category: "demo")

    /// The newest Add sheet's model, so a state can type and tap through it.
    @MainActor private(set) static weak var currentModel: AddSheetModel?

    /// The Add sheet made its model (DEBUG builds only).
    @MainActor
    static func sheetMade(_ model: AddSheetModel) {
        currentModel = model
    }

    /// The container to run on for `state`, or nil for the default demo container (the seeded
    /// inventory in memory, or an empty one with `-demoSeed empty`). Called before anything
    /// shows.
    @MainActor
    static func container(state: String, platform: AppPlatform) -> AppContainer? {
        guard let answer = State(rawValue: state)?.recognition else { return nil }
        return recognitionContainer(platform: platform, answer: answer)
    }

    /// Runs once the main shell shows, after `-demoTab` and before `-demoRoute`: opens the Add
    /// sheet in `state`.
    @MainActor
    static func run(state: String, app: AppContainer) async {
        guard let state = State(rawValue: state) else {
            let states = State.allCases.map(\.rawValue).joined(separator: ", ")
            log.error("-demoState \(state, privacy: .public) is not an Add state; use one of \(states, privacy: .public)")
            return
        }
        currentModel = nil
        let router = app.router
        let inventory = await AddDemoInventory.read(app)
        switch state {
        case .empty:
            router.present(.addItem(AddParams()))
        case .into:
            router.present(.addItem(AddParams(containerId: inventory.toolChest, name: "Drill bits")))
        case .loading, .offered, .details, .failed:
            guard let photo = await demoPhoto(app) else { return }
            router.present(.addItem(AddParams(containerId: inventory.toolChest, photo: photo)))
            guard state == .details, let model = await sheetModel(), await until({ model.detailsShown }) else { return }
            try? await Task.sleep(for: .milliseconds(300))
            AddDemoSignals.shared.scrollToEnd += 1
        case .stale, .refreshed:
            guard let photo = await demoPhoto(app) else { return }
            var params = AddParams(containerId: inventory.toolChest, photo: photo)
            // A title the (demo) suggestion does not match: its details describe its own guess.
            params.name = "Angle grinder"
            router.present(.addItem(params))
            guard state == .refreshed, let model = await sheetModel(), await until({ model.staleName != nil }) else { return }
            model.refreshSuggestion()
        case .place:
            router.present(.addItem(AddParams()))
            guard let model = await sheetModel() else { return }
            try? await Task.sleep(for: .milliseconds(700))
            model.showPlaceStep()
        case .saveProblem:
            await saveProblem(app, inventory: inventory)
        case .savedNext:
            router.present(.addItem(AddParams(containerId: inventory.redBin)))
            guard let model = await sheetModel(), await until({ model.places != nil }) else { return }
            try? await Task.sleep(for: .milliseconds(700))
            model.name = "Wood screws"
            model.setQuantity(40)
            await model.save(andAnother: true)
        case .draft:
            app.drafts.keepDraft(
                owner: "add-demo",
                draft: AddDraft(
                    state: AddDraftState(
                        values: ItemFormValues(name: "Wood screws", category: "Hardware", quantity: "40"),
                        placeId: inventory.redBin ?? DropZone.containerId,
                        picked: nil,
                        photo: nil,
                        suggestion: .idle,
                        showMore: false
                    ),
                    savedAt: app.now()
                )
            )
            router.present(.addItem(AddParams()))
        }
    }

    /// A save into a container that went while the sheet was open (deleted elsewhere): the item
    /// is not written and the notice says so, the typing kept.
    @MainActor
    private static func saveProblem(_ app: AppContainer, inventory: AddDemoInventory) async {
        var crateId: String?
        if let garage = inventory.garage {
            crateId = try? await app.repositories.containers.create(CreateContainerInput(spaceId: garage, name: "Old crate", visualType: .crate)).id
        }
        app.router.present(.addItem(AddParams(containerId: crateId)))
        guard let model = await sheetModel(), await until({ model.places != nil || model.showsPlacesFailed }) else { return }
        try? await Task.sleep(for: .milliseconds(700))
        // Gone under the sheet, without telling it (nothing invalidates): as from another phone.
        if let crateId { _ = try? await app.repositories.containers.delete(crateId) }
        model.name = "Paint brushes"
        await model.save(andAnother: false)
    }

    /// The model of the sheet just presented, once it has made one.
    @MainActor
    private static func sheetModel() async -> AddSheetModel? {
        guard await until({ currentModel != nil }) else {
            log.error("-demoState: the Add sheet did not appear")
            return nil
        }
        return currentModel
    }

    /// Waits up to 8 s for `condition`.
    @MainActor
    private static func until(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<160 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// A photo stored like a capture: a drill-ish picture drawn in place.
    @MainActor
    private static func demoPhoto(_ app: AppContainer) async -> StoredImage? {
        let size = CGSize(width: 720, height: 720)
        let image = UIGraphicsImageRenderer(size: size, format: { let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format }()).image { context in
            UIColor(red: 0.93, green: 0.62, blue: 0.24, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let configuration = UIImage.SymbolConfiguration(pointSize: 360, weight: .regular)
            if let symbol = UIImage(systemName: "wrench.and.screwdriver.fill", withConfiguration: configuration)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let origin = CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2)
                symbol.draw(at: origin)
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        do {
            return try await app.imageStore.storeItemPhoto(.image(cgImage), cropToAspect: nil)
        } catch {
            log.error("-demoState: the demo photo was not stored")
            return nil
        }
    }

    /// The seeded preview inventory with recognition answering `answer` from
    /// ``AddDemoRecognitionTransport`` (`AppContainer.preview` has no recognition endpoint).
    @MainActor
    private static func recognitionContainer(platform: AppPlatform, answer: AddDemoRecognitionTransport.Answer) -> AppContainer {
        let root = URL.temporaryDirectory.appending(path: "inventory-add-demo-\(UUID().uuidString)", directoryHint: .isDirectory)
        let resolver = PhotoPathResolver(
            documents: root.appending(path: "Documents", directoryHint: .isDirectory),
            caches: root.appending(path: "Library/Caches", directoryHint: .isDirectory)
        )
        return AppContainer(
            dependencies: AppContainer.Dependencies(
                config: AppConfig(recognitionEndpoint: "https://recognition.invalid/v1/recognize", recognitionTimeoutMs: 3_600_000),
                keychain: InMemoryKeychain(),
                preferences: InMemoryPreferences([PreferenceKey.onboardingCompleted: "true"]),
                openDatabase: {
                    let store = try DatabaseStore.inMemory()
                    try await store.migrate()
                    try await AppContainerPreviewData.seed(
                        LocalRepositories(store: store, environment: AppContainerPreviewData.environment),
                        photos: ImageStore(resolver: resolver)
                    )
                    return store
                },
                transport: AddDemoRecognitionTransport(answer: answer),
                networkTelemetry: NetworkTelemetry(event: { _, _ in }, error: { _, _ in }),
                photoPathResolver: resolver,
                protectedData: HouseholdModel.ProtectedDataGate(isAvailable: { true }, waitUntilAvailable: {}),
                bootSystem: .inert
            ),
            platform: platform
        )
    }
}

/// What a demo state asks of the sheet's view (DEBUG only).
@MainActor
@Observable
final class AddDemoSignals {
    static let shared = AddDemoSignals()
    /// Bumped to scroll the form to its last row.
    var scrollToEnd = 0
}

/// The seeded places the demo states open the sheet for.
private struct AddDemoInventory {
    var garage: String?
    var toolChest: String?
    var redBin: String?

    @MainActor
    static func read(_ app: AppContainer) async -> AddDemoInventory {
        let containers = (try? await app.repositories.containers.listAllWithSpace()) ?? []
        let spaces = (try? await app.repositories.spaces.listWithCounts()) ?? []
        return AddDemoInventory(
            garage: spaces.first { $0.name == "Garage" }?.id,
            toolChest: containers.first { $0.container.name == "Tool chest" }?.container.id,
            redBin: containers.first { $0.container.name == "Red bin" }?.container.id
        )
    }
}

/// The recognition endpoint, answered in the app (DEBUG demo only): held forever, a suggestion
/// for a cordless drill that ignores the name hint, or "too many requests".
struct AddDemoRecognitionTransport: HTTPTransport {
    enum Answer: Sendable {
        case hold
        case suggestion
        case rateLimited
    }

    let answer: Answer

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        switch answer {
        case .hold:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        case .suggestion:
            try await Task.sleep(for: .milliseconds(900))
            let body = #"{"contractVersion":1,"suggestion":{"name":"Cordless drill","category":"Power tools","tags":["drill","18V"],"confidence":0.86}}"#
            return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(body.utf8))
        case .rateLimited:
            try await Task.sleep(for: .milliseconds(900))
            return HTTPResponse(status: 429, headers: ["content-type": "application/json"], body: Data(#"{"error":"rate_limited"}"#.utf8))
        }
    }
}

/// The app showing the Add sheet in a demo state, for `#Preview`s: the shell with the state's
/// container, the sheet opened and driven as `-demoArea add -demoState <state>` does.
struct AddSheetPreview: View {
    let state: AddDemo.State
    @State private var app: AppContainer

    init(_ state: AddDemo.State) {
        self.state = state
        _app = State(initialValue: AddDemo.container(state: state.rawValue, platform: .silent()) ?? AppContainer.preview())
    }

    var body: some View {
        RootView()
            .shellEnvironment(app)
            .task(id: app.boot.phase == .main) {
                if app.boot.phase == .main { await AddDemo.run(state: state.rawValue, app: app) }
            }
    }
}
#endif
