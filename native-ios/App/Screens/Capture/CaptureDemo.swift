#if DEBUG
import Foundation
import InventoryAppModels
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryStrings

/// DEBUG demo hooks for the capture area: the camera, Quick Snap and its review, every state
/// reachable without a tap:
/// `mac.sh run out.png -demo YES -demoArea capture -demoState <state>`.
///
/// The simulator has no camera, so under `-demo YES` there the camera is a stand-in
/// (`CaptureStandInFeed`): a drawn scene that runs at once and hands back drawn photos, with the
/// permission granted. That also holds without `-demoArea`, so `-demoRoute quickSnap` and the
/// shell's UI tests get a working shutter.
///
/// | State | Shows |
/// |---|---|
/// | `single` | the single-photo camera into the Tool chest (the Into pill's location line) |
/// | `request` | the camera the Add sheet opens for one photo: no mode picker, no Type it instead |
/// | `flash` | the single camera with the flash on |
/// | `singleShot` | the single camera taking a photo by itself: it hands over to the Add sheet carrying it |
/// | `singleProcessing` | the single camera taking a photo that is never done saving: the busy shutter ("Saving…") |
/// | `fast` | Quick Snap before the first shot (Done dimmed) |
/// | `fastShots` | Quick Snap taking three shots by itself; recognition answers after 8 s: "Identifying 3…", then "2 identified · 1 to name" |
/// | `fastDone` | Quick Snap taking two shots and pressing Done by itself: the review pushed over the camera |
/// | `didNotStart` | a camera that could not start: the error notice with Type it instead |
/// | `noPhoto` | Quick Snap whose capture failed before any shot: the error notice with Type it instead |
/// | `notices` | Quick Snap with two shots saved, one dropped and a failed capture: both notices, the set locked (no Type it instead) |
/// | `permission` | the permission gate before the system prompt (Allow grants the stand-in) |
/// | `blocked` | the permission gate after a refusal (Open Settings) |
/// | `permissionRequest` | the gate for the Add sheet's photo: no Type it instead |
/// | `reviewArriving` | a review with two rows landed and two on their way; a third lands after 4 s |
/// | `reviewSavingFirst` | a review before any row has landed |
/// | `reviewNamed` | every row named |
/// | `reviewToName` | a container's set with an unnamed row |
/// | `reviewStalled` | two of three landed and nothing changed for 30 s: "Some photos may not have been saved." (`RUN_SETTLE_SECONDS=36`) |
/// | `reviewNothing` | nothing saved: Try again |
/// | `reviewEmptied` | rows that landed and were then deleted elsewhere |
enum CaptureDemo {
    /// The container for `state`: one whose recognition answers for `fastShots`, else the
    /// default demo container. Also sets up the stand-in camera for every state.
    @MainActor
    static func container(state: String, platform: AppPlatform) -> AppContainer? {
        CaptureStandIn.current = standIn(for: state)
        holdsPhotos = state == "singleProcessing"
        guard state == "fastShots" else { return nil }
        return recognizingContainer(platform: platform)
    }

    /// `singleProcessing`: the capture screens store photos that never finish saving.
    @MainActor private static var holdsPhotos = false

    /// The photo store a capture screen saves through: the app's, or one that never finishes
    /// for `singleProcessing`.
    @MainActor
    static func photos(_ base: any PhotoStoring) -> any PhotoStoring {
        holdsPhotos ? CaptureDemoHeldPhotos(base: base) : base
    }

    /// Opens the state's screen once the main shell shows.
    @MainActor
    static func run(state: String, app: AppContainer) async {
        let router = app.router
        switch state {
        case "single", "flash", "didNotStart", "singleShot", "singleProcessing":
            router.present(.cover(.capture(CaptureRoute(containerId: await toolChestId(app) ?? DropZone.containerId), request: nil)))
        case "request", "permissionRequest":
            let containerId = await toolChestId(app) ?? DropZone.containerId
            Task {
                _ = await router.presentForResult(StoredImage.self) { .cover(.capture(CaptureRoute(containerId: containerId), request: $0)) }
            }
        case "fast", "fastShots", "fastDone", "noPhoto", "notices", "permission", "blocked":
            router.openQuickSnap()
        case "reviewArriving":
            let since = app.now() - 1
            await openReview(app, QuickSnapReviewRoute(containerId: DropZone.containerId, since: since, expected: 4))
            await seed(app, names: ["Cordless drill", ""])
            try? await Task.sleep(for: .seconds(4))
            await seed(app, names: ["Tape measure"])
        case "reviewSavingFirst":
            await openReview(app, QuickSnapReviewRoute(containerId: DropZone.containerId, since: app.now(), expected: 3))
        case "reviewNamed":
            let since = app.now() - 1
            await openReview(app, QuickSnapReviewRoute(containerId: DropZone.containerId, since: since, expected: 3))
            await seed(app, names: ["Cordless drill", "Tape measure", "Wood glue"])
        case "reviewToName":
            guard let toolChest = await toolChestId(app) else { return }
            let since = app.now() - 1
            await openReview(app, QuickSnapReviewRoute(containerId: toolChest, since: since, expected: 3))
            await seed(app, names: ["Spirit level", "", "Socket set"], containerId: toolChest)
        case "reviewStalled":
            let since = app.now() - 1
            await openReview(app, QuickSnapReviewRoute(containerId: DropZone.containerId, since: since, expected: 3))
            await seed(app, names: ["Cordless drill", ""])
        case "reviewNothing":
            await openReview(app, QuickSnapReviewRoute(containerId: DropZone.containerId, since: app.now(), expected: 0))
        case "reviewEmptied":
            let since = app.now() - 1
            await openReview(app, QuickSnapReviewRoute(containerId: DropZone.containerId, since: since, expected: 2))
            let ids = await seed(app, names: ["Cordless drill", ""])
            try? await Task.sleep(for: .seconds(2))
            for id in ids { _ = try? await app.repositories.items.delete(id) }
            app.database.invalidate()
        default:
            if !state.isEmpty { ShellDemo.log.error("-demoState \(state, privacy: .public) is not a capture state") }
        }
    }

    // MARK: The stand-in camera

    /// The stand-in for `state`; nil keeps the real camera (a device with one).
    @MainActor
    static func standIn(for state: String) -> CaptureStandIn.Configuration? {
        typealias Script = CaptureStandInFeed.Script
        let script: Script = switch state {
        case "flash": Script(flashOn: true)
        case "fastShots": Script(shots: [.photo, .photo, .photo])
        case "singleShot", "singleProcessing": Script(shots: [.photo])
        case "fastDone": Script(shots: [.photo, .photo], finishes: true)
        case "didNotStart": Script(failsToStart: true)
        case "noPhoto": Script(shots: [.fails])
        case "notices": Script(shots: [.photo, .unreadable, .photo, .fails])
        default: Script()
        }
        let permission: CaptureStandInPermission? = switch state {
        case "permission", "permissionRequest": CaptureStandInPermission(.notDetermined)
        case "blocked": CaptureStandInPermission(.denied)
        default: CaptureStandInPermission(.authorized)
        }
        return CaptureStandIn.Configuration(permission: permission, script: script)
    }

    /// `-demo YES` on the simulator without `-demoArea capture`: the stand-in, granted, so Quick
    /// Snap and the single camera work there (the simulator has no camera to ask for).
    @MainActor
    static func installDefaultStandIn() {
        #if targetEnvironment(simulator)
        guard UserDefaults.standard.bool(forKey: "demo"), CaptureStandIn.current == nil else { return }
        CaptureStandIn.current = CaptureStandIn.Configuration(permission: CaptureStandInPermission(.authorized))
        #endif
    }

    // MARK: Helpers

    @MainActor
    private static func toolChestId(_ app: AppContainer) async -> String? {
        let containers = (try? await app.repositories.containers.listAllWithSpace()) ?? []
        return containers.first { $0.container.name == "Tool chest" }?.container.id
    }

    /// The review pushed over a Quick Snap camera, as Done leaves it: through `CaptureNavigator`,
    /// so popping the review closes the camera under it, as after a real set. The push waits for
    /// the cover to be up: a stack presented with a screen already pushed has no destination for
    /// it yet.
    @MainActor
    private static func openReview(_ app: AppContainer, _ route: QuickSnapReviewRoute) async {
        let camera = app.router.present(.cover(.capture(CaptureRoute(containerId: route.containerId, mode: .fast), request: nil)))
        try? await Task.sleep(for: .milliseconds(800))
        CaptureNavigator(router: app.router, address: camera.address).navigate(.review(route))
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// Writes one Quick Snap row per name ("" for one recognition could not name), each with a
    /// drawn photo, as the pipeline would, then invalidates.
    @MainActor
    @discardableResult
    private static func seed(_ app: AppContainer, names: [String], containerId: String = DropZone.containerId) async -> [String] {
        var ids: [String] = []
        for (index, name) in names.enumerated() {
            let data = CaptureStandInFeed.photoData(index: index + 1)
            guard let stored = try? await app.imageStore.storeItemPhoto(.data(data), cropToAspect: nil) else { continue }
            let photo = ItemPhotoInput(uri: stored.uri, thumbUri: stored.thumbUri, width: stored.width, height: stored.height, byteSize: stored.byteSize)
            let draft = ItemDraft(containerId: containerId, name: name.isEmpty ? nil : name, photo: photo)
            if let item = try? await app.repositories.items.create(draft) { ids.append(item.id) }
            // Each row a millisecond apart, so they sort as shot.
            try? await Task.sleep(for: .milliseconds(5))
        }
        app.database.invalidate()
        return ids
    }

    // MARK: A container whose recognition answers

    /// The seeded demo container, with photo recognition configured and answered by
    /// ``CaptureDemoRecognitionTransport`` (everything else stays offline).
    @MainActor
    private static func recognizingContainer(platform: AppPlatform) -> AppContainer {
        let root = URL.temporaryDirectory.appending(path: "inventory-capture-demo-\(UUID().uuidString)", directoryHint: .isDirectory)
        let resolver = PhotoPathResolver(
            documents: root.appending(path: "Documents", directoryHint: .isDirectory),
            caches: root.appending(path: "Library/Caches", directoryHint: .isDirectory)
        )
        var config = AppConfig()
        config.recognitionEndpoint = "https://recognition.demo.invalid/api/recognize"
        return AppContainer(
            dependencies: AppContainer.Dependencies(
                config: config,
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
                transport: CaptureDemoRecognitionTransport(),
                networkTelemetry: NetworkTelemetry(event: { _, _ in }, error: { _, _ in }),
                photoPathResolver: resolver,
                protectedData: HouseholdModel.ProtectedDataGate(isAvailable: { true }, waitUntilAvailable: {}),
                bootSystem: .inert
            ),
            platform: platform
        )
    }
}

/// The app's photo store, except that a new photo is never done saving (`singleProcessing`).
private struct CaptureDemoHeldPhotos: PhotoStoring {
    let base: any PhotoStoring

    func storeItemPhoto(_ source: ImageSource, cropToAspect aspect: CGSize?) async throws -> StoredImage {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }

    func writeStoredPhoto(photoId: String, bytes: Data) async throws -> StoredImage {
        try await base.writeStoredPhoto(photoId: photoId, bytes: bytes)
    }

    func readStoredPhoto(_ uri: String) async -> Data? {
        await base.readStoredPhoto(uri)
    }

    func deleteStoredPhotos(_ uris: [String?]) {
        base.deleteStoredPhotos(uris)
    }

    func hasRoomForPhoto(estimatedBytes: Int64) -> Bool {
        base.hasRoomForPhoto(estimatedBytes: estimatedBytes)
    }
}

/// Answers recognition after 8 s, naming the first two photos and not the third (then round
/// again); every other request is offline.
private actor CaptureDemoRecognitionTransport: HTTPTransport {
    private var answered = 0

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard request.url?.host() == "recognition.demo.invalid" else { throw URLError(.notConnectedToInternet) }
        let names = ["Cordless drill", "Tape measure", nil]
        let name = names[answered % names.count]
        answered += 1
        try await Task.sleep(for: .seconds(8))
        let body = if let name {
            #"{"contractVersion":1,"suggestion":{"name":"\#(name)","category":"Tools","tags":["demo"],"confidence":0.9}}"#
        } else {
            #"{"contractVersion":1,"status":"unrecognized"}"#
        }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(body.utf8))
    }
}
#endif
