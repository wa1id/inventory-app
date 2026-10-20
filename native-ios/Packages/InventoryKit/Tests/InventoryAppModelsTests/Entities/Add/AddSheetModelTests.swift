import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryStrings
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryAppModels

/// Recognition that answers from a script; with `hold`, each request waits until released.
actor EntitiesRecognizer {
    private var results: [RecognitionResult]
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [(uri: String, hint: String?)] = []
    var hold = false

    init(_ results: [RecognitionResult] = []) {
        self.results = results
    }

    func setHold(_ hold: Bool) { self.hold = hold }
    func script(_ more: [RecognitionResult]) { results.append(contentsOf: more) }
    var heldCount: Int { held.count }
    var hints: [String?] { requests.map(\.hint) }

    func release() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume()
    }

    func recognize(_ uri: String, _ hint: String?) async -> RecognitionResult {
        requests.append((uri, hint))
        if hold { await withCheckedContinuation { held.append($0) } }
        return results.isEmpty ? .failed(.unrecognized) : results.removeFirst()
    }

    static func waitForHeld(_ recognizer: EntitiesRecognizer, count: Int) async {
        // A real-time limit, not a count of yields: a loaded Mac can hold the model's tasks back
        // for seconds. The wait ends as soon as the condition holds.
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if await recognizer.heldCount >= count { return }
            await Task.yield()
        }
        Issue.record("expected \(count) held recognition(s)")
    }
}

/// The Add sheet model's tests: 06 §10, 07 §3.1, and the Swift tests 06 §10.7 asks for.
@MainActor
@Suite("AddSheetModel (app/item/new.tsx)")
struct EntitiesAddSheetModelTests {
    @MainActor
    final class Harness {
        let items: EntitiesFakeItems
        let spaces: EntitiesFakeSpaces
        let containers: any ContainersRepository
        let photos = EntitiesPhotoSpy()
        let drafts: AddDraftStore
        let recognizer: EntitiesRecognizer
        let preferences = InMemoryPreferences()
        let categories: CategoryMemory
        let toasts = SharedSeamsToastRecorder()
        let confirm: SharedSeamsConfirmScript
        let haptics = SharedSeamsHapticRecorder()
        let invalidations = SharedSeamsInvalidationCounter()
        let telemetry = RecordingTelemetry()
        let screen = EntitiesScreenStub()
        let camera = EntitiesCameraStub()
        let clock = EntitiesNow(1_000_000)

        init(
            items: EntitiesFakeItems = EntitiesFakeItems(),
            spaces: EntitiesFakeSpaces = EntitiesFakeSpaces(),
            containers: any ContainersRepository = EntitiesFakeContainers(),
            recognizer: EntitiesRecognizer = EntitiesRecognizer(),
            drafts: AddDraftStore? = nil,
            confirm: SharedSeamsConfirmScript = SharedSeamsConfirmScript()
        ) {
            self.items = items
            self.spaces = spaces
            self.containers = containers
            self.recognizer = recognizer
            self.drafts = drafts ?? AddDraftStore(photos: photos)
            self.confirm = confirm
            categories = CategoryMemory(preferences: preferences)
        }

        var now: Int64 {
            get { clock.ms }
            set { clock.set(newValue) }
        }

        func makeModel(_ params: AddParams = AddParams(), owner: String = "sheet-1") -> AddSheetModel {
            let screen = screen
            let camera = camera
            let recognizer = recognizer
            let clock = clock
            return AddSheetModel(
                params: params,
                spaces: spaces,
                containers: containers,
                items: items,
                drafts: drafts,
                photos: photos,
                recognize: { await recognizer.recognize($0, $1) },
                recentPlaces: RecentPlacesStore(preferences: preferences),
                categories: categories,
                invalidator: invalidations,
                toasts: toasts,
                confirm: confirm,
                haptics: haptics.player,
                routing: AddSheetModel.Routing(
                    isFocused: { screen.focused },
                    close: { screen.closes += 1 },
                    replaceWithCapture: { camera.replacements.append(($0, $1)) },
                    takePhoto: { containerId in
                        camera.opened.append(containerId)
                        return camera.photos.isEmpty ? nil : camera.photos.removeFirst()
                    }
                ),
                telemetry: TelemetryReporter(sink: telemetry),
                now: { clock.ms },
                owner: owner
            )
        }
    }

    private static let stored = StoredImage(uri: "file:///p.webp", thumbUri: "file:///p-thumb.webp", width: 1400, height: 1050, byteSize: 2048)

    private static func found(_ name: String?, category: String? = "Power Tools", tags: [String] = ["dewalt", "18v"], confidence: Double = 0.9) -> RecognitionResult {
        .success(RecognitionSuggestion(name: name, category: category, tags: tags, confidence: confidence), contractVersion: 1)
    }

    private static func garage() -> (EntitiesFakeSpaces, EntitiesFakeContainers) {
        let space = Space(id: "garage", name: "Garage", icon: "🚗", color: "#5B8DEF", createdAt: 1, updatedAt: 1)
        let chest = Container(id: "chest", spaceId: "garage", name: "Tool chest", visualType: .cabinet, shortCode: "CAB-J92R", createdAt: 1, updatedAt: 1)
        return (
            EntitiesFakeSpaces([.value([SpaceWithCounts(space: space, containerCount: 1, itemCount: 0)])]),
            EntitiesFakeContainers([.value([ContainerWithSpace(container: chest, spaceName: "Garage", itemCount: 0)])])
        )
    }

    // MARK: Drafts

    @Test("a plain open starts empty in the drop zone and keeps no draft")
    func plainOpen() {
        let harness = Harness()
        let model = harness.makeModel()
        model.start()
        #expect(model.values == .empty)
        #expect(model.place == ResolvedPlace(id: DropZone.containerId, option: nil))
        #expect(!model.restored)
        #expect(model.focusesNameOnArrival)
        #expect(harness.drafts.restorableDraft(now: harness.now) == nil)
    }

    @Test("typing keeps a draft that the next plain open restores")
    func draftRestores() {
        let harness = Harness()
        let first = harness.makeModel(owner: "first")
        first.start()
        first.name = "Torch"
        first.sheetClosed()

        let second = harness.makeModel(owner: "second")
        second.start()
        #expect(second.restored)
        #expect(second.values.name == "Torch")
        // A restored draft is still kept (now by the sheet that restored it).
        #expect(harness.drafts.restorableDraft(now: harness.now)?.state.values.name == "Torch")
    }

    @Test("opening for a container leaves an earlier draft alone")
    func openedForContainerKeepsDraft() {
        let harness = Harness()
        let first = harness.makeModel(owner: "first")
        first.start()
        first.name = "Torch"
        first.sheetClosed()

        let second = harness.makeModel(AddParams(containerId: "chest"), owner: "second")
        second.start()
        #expect(!second.restored)
        #expect(second.values.name == "")
        second.sheetClosed()
        #expect(harness.drafts.restorableDraft(now: harness.now)?.state.values.name == "Torch")
    }

    @Test("a stale draft is thrown away with its photo on the next plain open")
    func staleDraft() async {
        let harness = Harness(recognizer: EntitiesRecognizer([Self.found("Drill")]))
        let first = harness.makeModel(AddParams(photoUri: "file:///old.webp", photoThumbUri: "file:///old-thumb.webp"), owner: "first")
        first.start()
        await first.recognitionTask?.value
        first.sheetClosed()

        harness.now += AddDraftStore.ttlMs + 1
        let second = harness.makeModel(owner: "second")
        second.start()
        #expect(!second.restored)
        #expect(harness.photos.deleted == [["file:///old.webp", "file:///old-thumb.webp"]])
        #expect(harness.drafts.restorableDraft(now: harness.now) == nil)
    }

    @Test("clearing a restored draft drops its photo and starts over in the drop zone")
    func clearRestored() async {
        let harness = Harness(recognizer: EntitiesRecognizer([Self.found("Drill")]))
        let first = harness.makeModel(AddParams(containerId: "chest", photoUri: "file:///p.webp"), owner: "first")
        first.start()
        await first.recognitionTask?.value
        first.sheetClosed()

        let second = harness.makeModel(owner: "second")
        second.start()
        #expect(second.restored)
        let focus = second.nameFocusRequest
        second.clearRestored()
        #expect(harness.photos.deleted.first == ["file:///p.webp", nil])
        #expect(second.values == .empty)
        #expect(second.photo == nil)
        #expect(second.suggestion == .idle)
        #expect(second.placeId == DropZone.containerId)
        #expect(!second.restored)
        #expect(second.nameFocusRequest == focus + 1)
        #expect(harness.drafts.restorableDraft(now: harness.now) == nil)
    }

    // MARK: Recognition

    @Test("a photo from the camera is recognised on arrival and fills the blanks")
    func recognisesOnArrival() async {
        let harness = Harness(recognizer: EntitiesRecognizer([Self.found("Cordless drill")]))
        let model = harness.makeModel(AddParams(photoUri: "file:///p.webp"))
        #expect(model.suggestion == .running)
        #expect(!model.focusesNameOnArrival)
        model.start()
        await model.recognitionTask?.value
        #expect(await harness.recognizer.hints == [nil])
        #expect(model.values.name == "Cordless drill")
        #expect(model.values.category == "Power Tools")
        #expect(model.values.tags == "dewalt, 18v")
        #expect(model.suggestion == .applied(confidence: 0.9, forName: "Cordless drill"))
        #expect(model.suggestionBanner == model.suggestion)
    }

    @Test("an answer about a photo removed meanwhile is dropped")
    func staleAnswerDropped() async {
        let recognizer = EntitiesRecognizer([Self.found("Cordless drill")])
        await recognizer.setHold(true)
        let harness = Harness(recognizer: recognizer)
        let model = harness.makeModel(AddParams(photoUri: "file:///p.webp", photoThumbUri: "file:///t.webp"))
        model.start()
        await EntitiesRecognizer.waitForHeld(recognizer, count: 1)
        model.removePhoto()
        #expect(harness.photos.deleted == [["file:///p.webp", "file:///t.webp"]])
        await recognizer.release()
        await model.recognitionTask?.value
        #expect(model.values == .empty)
        #expect(model.suggestion == .idle)
        #expect(model.suggestionBanner == nil)
    }

    @Test("a photo removed before its recognition task has even run never takes the answer")
    func removedBeforeRecognitionRuns() async {
        let recognizer = EntitiesRecognizer([Self.found("Cordless drill"), Self.found("Drill")])
        let harness = Harness(recognizer: recognizer)
        let model = harness.makeModel(AddParams(photoUri: "file:///p.webp"))
        // No suspension between starting recognition and removing the photo: RN notes the photo
        // before its first await, so the answer is dropped however early the removal comes.
        model.start()
        model.removePhoto()
        await model.recognitionTask?.value
        #expect(model.values == .empty)
        #expect(model.suggestion == .idle)
        #expect(model.photo == nil)

        let other = Harness(recognizer: EntitiesRecognizer([Self.found("Drill")]))
        let retried = other.makeModel(AddParams(photoUri: "file:///q.webp"))
        retried.retrySuggestion()
        retried.removePhoto()
        await retried.recognitionTask?.value
        #expect(retried.values == .empty)
        #expect(retried.suggestion == .idle)
    }

    @Test("a name typed before the answer survives it, and the details then read as stale")
    func typedNameSurvives() async {
        let recognizer = EntitiesRecognizer([Self.found("Cordless drill")])
        await recognizer.setHold(true)
        let harness = Harness(recognizer: recognizer)
        let model = harness.makeModel(AddParams(photoUri: "file:///p.webp"))
        model.start()
        await EntitiesRecognizer.waitForHeld(recognizer, count: 1)
        model.name = "Angle grinder"
        await recognizer.release()
        await model.recognitionTask?.value
        #expect(model.values.name == "Angle grinder")
        #expect(model.values.category == "Power Tools")
        #expect(model.suggestion == .applied(confidence: 0.9, forName: "Cordless drill"))
        #expect(model.staleName == "Angle grinder")
        #expect(model.suggestionBanner == .stale(forName: "Angle grinder"))
    }

    @Test("updating the details replaces category and tags, never the name, and records the hint")
    func refreshOverwrites() async {
        let recognizer = EntitiesRecognizer([Self.found("Cordless drill"), Self.found("Bench grinder (echoed)", category: nil, tags: [])])
        let harness = Harness(recognizer: recognizer)
        let model = harness.makeModel(AddParams(photoUri: "file:///p.webp"))
        model.start()
        await model.recognitionTask?.value
        model.name = "Angle grinder"
        model.refreshSuggestion()
        #expect(model.suggestion == .refreshing)
        await model.recognitionTask?.value
        #expect(await recognizer.hints == [nil, "Angle grinder"])
        #expect(model.values.name == "Angle grinder")
        #expect(model.values.category == "")
        #expect(model.values.tags == "")
        // The hint, not the echoed name.
        #expect(model.suggestion == .refreshed(forName: "Angle grinder"))
        #expect(model.staleName == nil)
    }

    @Test("a failed answer offers a retry anchored to the typed name")
    func failureAndRetry() async {
        let recognizer = EntitiesRecognizer([.failed(.offline), Self.found("Drill")])
        let harness = Harness(recognizer: recognizer)
        let model = harness.makeModel(AddParams(name: "  Drill bits ", photoUri: "file:///p.webp"))
        model.start()
        await model.recognitionTask?.value
        #expect(model.suggestion == .failed(.offline))
        #expect(model.values.name == "Drill bits")
        model.retrySuggestion()
        #expect(model.suggestion == .running)
        await model.recognitionTask?.value
        #expect(await recognizer.hints == ["Drill bits", "Drill bits"])
        #expect(model.suggestion == .applied(confidence: 0.9, forName: "Drill"))
    }

    @Test("taking a photo starts recognition with the typed name; a second tap while the camera is up does nothing")
    func takePhoto() async {
        let recognizer = EntitiesRecognizer([Self.found("Drill")])
        let harness = Harness(recognizer: recognizer)
        harness.camera.photos = [Self.stored]
        let model = harness.makeModel()
        model.start()
        model.name = "Drill"
        await model.takePhoto()
        await model.recognitionTask?.value
        #expect(harness.camera.opened == [DropZone.containerId])
        #expect(model.photo == AddPhoto(uri: "file:///p.webp", thumbUri: "file:///p-thumb.webp", width: 1400, height: 1050, byteSize: 2048))
        #expect(await recognizer.hints == ["Drill"])
        #expect(model.suggestion == .applied(confidence: 0.9, forName: "Drill"))

        // The camera closed without a photo: nothing changes.
        await model.takePhoto()
        #expect(model.photo?.uri == "file:///p.webp")
    }

    @Test("retaking drops the old photo before the camera opens")
    func retake() async {
        let harness = Harness(recognizer: EntitiesRecognizer([Self.found("A"), Self.found("B")]))
        harness.camera.photos = [StoredImage(uri: "file:///new.webp", thumbUri: "file:///new-t.webp", width: 1, height: 1, byteSize: nil)]
        let model = harness.makeModel(AddParams(photoUri: "file:///old.webp"))
        model.start()
        await model.recognitionTask?.value
        await model.retakePhoto()
        await model.recognitionTask?.value
        #expect(harness.photos.deleted.first == ["file:///old.webp", nil])
        #expect(model.photo?.uri == "file:///new.webp")
    }

    @Test("a quantity change applies to the latest values, never undoing a suggestion")
    func quantityOnLatest() async {
        let harness = Harness(recognizer: EntitiesRecognizer([Self.found("Drill")]))
        let model = harness.makeModel(AddParams(photoUri: "file:///p.webp"))
        model.start()
        await model.recognitionTask?.value
        model.setQuantity(4)
        #expect(model.values.name == "Drill")
        #expect(model.values.quantity == "4")
        #expect(model.quantity == 4)
    }

    @Test("the Category chips come from the categories this phone knows")
    func categorySuggestions() {
        let harness = Harness()
        harness.categories.record("Tools")
        harness.categories.record("Toys")
        let model = harness.makeModel()
        model.category = "to"
        #expect(model.categorySuggestions == ["Toys", "Tools"])
        model.category = "Tools"
        #expect(model.categorySuggestions == [])
    }

    // MARK: Places

    @Test("the places read fills the where list; the opened-for container titles the sheet")
    func places() async {
        let (spaces, containers) = Self.garage()
        let harness = Harness(spaces: spaces, containers: containers)
        harness.preferences.setString(#"["chest","gone"]"#, forKey: PreferenceKey.recentPlaces)
        let model = harness.makeModel(AddParams(containerId: "chest"))
        model.start()
        #expect(model.title == L10n.Add.title)
        #expect(model.entries == [.dropZone])
        await model.loadPlaces()
        let chest = model.options?["chest"]
        #expect(chest?.spaceColor == "#5B8DEF")
        #expect(model.title == L10n.Add.titleTo(container: "Tool chest"))
        #expect(model.entries.map(\.id) == ["chest", DropZone.containerId])
        #expect(model.saveAccessibilityLabel == "Save in Tool chest, Garage")
        #expect(!model.showsPlacesFailed)
    }

    @Test("a failed places read with nothing loaded says so; a later failure keeps what was loaded")
    func placesFail() async {
        let (spaces, _) = Self.garage()
        let harness = Harness(spaces: spaces, containers: EntitiesFakeContainers([.failure(EntitiesFailure("db"))]))
        let model = harness.makeModel()
        await model.loadPlaces()
        #expect(model.showsPlacesFailed)
        #expect(model.places == nil)

        let chest = Container(id: "chest", spaceId: "garage", name: "Tool chest", visualType: .cabinet, shortCode: "CAB-J92R", createdAt: 1, updatedAt: 1)
        let flaky = EntitiesFakeContainers([
            .value([ContainerWithSpace(container: chest, spaceName: "Garage", itemCount: 0)]),
            .failure(EntitiesFailure("db")),
        ])
        let (goodSpaces, _) = Self.garage()
        let other = Harness(spaces: goodSpaces, containers: flaky)
        let loaded = other.makeModel()
        await loaded.loadPlaces()
        #expect(loaded.places?.count == 1)
        await loaded.loadPlaces()
        #expect(loaded.places?.count == 1)
        #expect(loaded.placesCause != nil)
        #expect(!loaded.showsPlacesFailed)
        #expect(!loaded.placesLoading)
    }

    @Test("a places read whose task was cancelled settles nothing, so it never reads as failed")
    func placesCancelled() async {
        let chest = Container(id: "chest", spaceId: "garage", name: "Tool chest", visualType: .cabinet, shortCode: "CAB-J92R", createdAt: 1, updatedAt: 1)
        let containers = EntitiesFakeContainers([
            .failure(CancellationError()),
            .value([ContainerWithSpace(container: chest, spaceName: "Garage", itemCount: 0)]),
        ])
        let (spaces, _) = Self.garage()
        let harness = Harness(spaces: spaces, containers: containers)
        let model = harness.makeModel()
        // The view's `.task(id:)` restarting: the old read is cancelled as it runs.
        let cancelled = Task { await model.loadPlaces() }
        cancelled.cancel()
        await cancelled.value
        #expect(!model.showsPlacesFailed)
        #expect(model.placesCause == nil)
        #expect(model.places == nil)

        await model.loadPlaces()
        #expect(model.places?.map(\.id) == ["chest"])
        #expect(!model.placesLoading)
    }

    @Test("choosing a row selects it with a choice tick; the selected row does nothing")
    func choose() async throws {
        let (spaces, containers) = Self.garage()
        let harness = Harness(spaces: spaces, containers: containers)
        let model = harness.makeModel()
        await model.loadPlaces()
        model.choose(.dropZone)
        #expect(harness.haptics.played.isEmpty)
        let chest = try #require(model.options?["chest"])
        model.choose(.container(chest, source: .recent))
        #expect(model.placeId == "chest")
        #expect(harness.haptics.played == [.choice])
    }

    @Test("the place step picks a container, which stays listed, or the drop zone")
    func placeStep() {
        let harness = Harness()
        let model = harness.makeModel()
        model.showPlaceStep()
        #expect(model.isPickingPlace)
        let made = EntitiesFixtures.option("new", name: "Just made")
        model.pickPlace(.container(made))
        #expect(!model.isPickingPlace)
        #expect(model.place == ResolvedPlace(id: "new", option: made))
        #expect(model.entries.map(\.id) == ["new", DropZone.containerId])
        model.pickPlace(.dropZone)
        #expect(model.place.isDropZone)
        #expect(model.entries.map(\.id) == ["new", DropZone.containerId])
    }

    // MARK: More details

    @Test("details open when filled, close over these values, and reopen when a suggestion changes them")
    func moreDetails() async {
        let recognizer = EntitiesRecognizer([Self.found("Drill", category: "Tools", tags: [])])
        await recognizer.setHold(true)
        let harness = Harness(recognizer: recognizer)
        let model = harness.makeModel(AddParams(photoUri: "file:///p.webp"))
        model.start()
        #expect(!model.detailsShown)
        model.notes = "spare"
        #expect(model.detailsShown)
        model.toggleDetails()
        #expect(!model.detailsShown)
        await EntitiesRecognizer.waitForHeld(recognizer, count: 1)
        await recognizer.release()
        await model.recognitionTask?.value
        #expect(model.values.category == "Tools")
        #expect(model.detailsShown)
        model.toggleDetails()
        model.toggleDetails()
        #expect(model.showMore)
    }

    // MARK: Saving

    @Test("Save writes the item with its photo, closes, and says where it went with Undo")
    func save() async throws {
        let (spaces, containers) = Self.garage()
        let items = EntitiesFakeItems(create: .value(EntitiesFixtures.item(id: "added", containerId: "chest", name: "Drill")))
        let harness = Harness(items: items, spaces: spaces, containers: containers, recognizer: EntitiesRecognizer([Self.found("Drill")]))
        let model = harness.makeModel(AddParams(containerId: "chest", photoUri: "file:///p.webp", photoThumbUri: "file:///t.webp"))
        model.start()
        await model.loadPlaces()
        await model.recognitionTask?.value
        model.tags = " power ,, dewalt "
        model.category = " Tools "

        await model.save(andAnother: false)

        let draft = try #require(await items.creates.first)
        #expect(draft.containerId == "chest")
        #expect(draft.name == "Drill")
        #expect(draft.category == "Tools")
        #expect(draft.tags == ["power", "dewalt"])
        #expect(draft.quantity == 1)
        #expect(draft.notes == nil)
        #expect(draft.photo == ItemPhotoInput(uri: "file:///p.webp", thumbUri: "file:///t.webp"))
        #expect(harness.telemetry.events == [RecordingTelemetry.Entry(
            level: "event", name: "item_created",
            payload: ["hasPhoto": .bool(true), "suggestionAccepted": .bool(true), "hinted": .bool(false)])])
        #expect(harness.drafts.restorableDraft(now: harness.now) == nil)
        #expect(harness.invalidations.count == 1)
        #expect(harness.haptics.played == [.success])
        #expect(RecentPlacesStore(preferences: harness.preferences).read() == ["chest"])
        #expect(harness.categories.known.first == "Tools")
        #expect(harness.screen.closes == 1)
        let toast = try #require(harness.toasts.last)
        #expect(toast.message == "Saved in Tool chest (Garage).")
        #expect(toast.action?.accessibilityLabel == L10n.Add.undoA11y(name: "Drill"))
        // The sheet has gone: later changes write no draft.
        model.name = "Something else"
        #expect(harness.drafts.restorableDraft(now: harness.now) == nil)
    }

    @Test("Undo deletes the item and its photo files")
    func undoAdd() async {
        let items = EntitiesFakeItems(
            create: .value(EntitiesFixtures.item(id: "added")),
            delete: .value(DeletionResult(deleted: true, orphanedPhotoUris: ["r2:abc"])))
        let harness = Harness(items: items)
        let model = harness.makeModel(AddParams(photoUri: "file:///p.webp", photoThumbUri: "file:///t.webp"))
        model.name = "Drill"
        await model.save(andAnother: false)
        harness.toasts.pressAction()
        await model.undoTask?.value
        #expect(await items.deletes == ["added"])
        #expect(harness.photos.deleted.last == ["r2:abc", "file:///p.webp", "file:///t.webp"])
        #expect(harness.telemetry.names.last == "item_deleted")
        #expect(harness.invalidations.count == 2)
        #expect(harness.haptics.played == [.success, .undo])
        #expect(harness.toasts.last?.message == L10n.Add.removedAgain)
    }

    @Test("a failed Undo says whether it was the connection")
    func undoFails() async {
        let items = EntitiesFakeItems(delete: .failure(HouseholdHttpError(status: 0, code: "offline")))
        let harness = Harness(items: items)
        let model = harness.makeModel()
        model.name = "Drill"
        await model.save(andAnother: false)
        harness.toasts.pressAction()
        await model.undoTask?.value
        #expect(harness.telemetry.errors.map(\.name) == ["item_delete_failed"])
        #expect(harness.telemetry.errors.first?.payload == ["errorClass": .string("offline")])
        #expect(harness.haptics.played == [.success, .error])
        #expect(harness.toasts.last?.message == L10n.Add.undoFailed(offline: true))
        #expect(harness.toasts.last?.tone == .error)
    }

    @Test("Save and add another without a photo stays for the next one in the same place")
    func saveAndAnother() async {
        let harness = Harness()
        let model = harness.makeModel(AddParams(containerId: "chest"))
        model.start()
        model.name = "Glue"
        model.notes = "white"
        let focus = model.nameFocusRequest
        await model.save(andAnother: true)
        #expect(model.values == .empty)
        #expect(model.placeId == "chest")
        #expect(model.savedNext)
        #expect(model.saving == nil)
        #expect(model.nameFocusRequest == focus + 1)
        #expect(model.scrollToTopRequest == 1)
        #expect(harness.toasts.shown.isEmpty)
        #expect(harness.screen.closes == 0)
        // Typing the next name clears the line; the next save works.
        model.name = "Tape"
        #expect(!model.savedNext)
        await model.save(andAnother: false)
        #expect(await harness.items.creates.count == 2)
    }

    @Test("Save and add another after a photo opens the camera again, for the same place")
    func saveAndAnotherWithPhoto() async {
        let harness = Harness()
        let model = harness.makeModel(AddParams(containerId: "chest", photoUri: "file:///p.webp"))
        model.name = "Drill"
        await model.save(andAnother: true)
        #expect(harness.camera.replacements.map(\.containerId) == ["chest"])
        #expect(harness.camera.replacements.map(\.fast) == [false])
        #expect(harness.screen.closes == 0)
        #expect(harness.toasts.shown.isEmpty)
        // The sheet is leaving: Save stays locked.
        await model.save(andAnother: false)
        #expect(await harness.items.creates.count == 1)
    }

    @Test("a failed save keeps everything and says why in the sheet")
    func saveFails() async {
        let harness = Harness(items: EntitiesFakeItems(create: .failure(HouseholdHttpError(status: 404, code: "not_found"))))
        let model = harness.makeModel()
        model.start()
        model.name = "Drill"
        await model.save(andAnother: false)
        #expect(model.problem == SaveNoticeCopy(cause: HouseholdHttpError(status: 404, code: "not_found"), subject: .container))
        #expect(model.problem?.title == L10n.Errors.Gone.container)
        #expect(harness.telemetry.errors == [RecordingTelemetry.Entry(level: "error", name: "item_create_failed", payload: ["errorClass": .string("gone")])])
        #expect(harness.haptics.played == [.error])
        #expect(model.saving == nil)
        #expect(harness.drafts.restorableDraft(now: harness.now)?.state.values.name == "Drill")
        #expect(harness.screen.closes == 0)
    }

    @Test("a save that fails after the sheet was closed under it says so in a toast")
    func saveFailsClosed() async {
        let harness = Harness(items: EntitiesFakeItems(create: .failure(EntitiesFailure("SQLITE_FULL"))))
        harness.screen.focused = false
        let model = harness.makeModel()
        model.name = "Drill"
        await model.save(andAnother: false)
        #expect(model.problem == nil)
        #expect(harness.toasts.last?.message == L10n.Errors.Local.save)
        #expect(harness.toasts.last?.tone == .error)
    }

    @Test("a blank name asks for one and saves nothing; an invalid quantity alone does nothing")
    func invalid() async {
        let harness = Harness()
        let model = harness.makeModel()
        await model.save(andAnother: false)
        #expect(model.nameError == L10n.Add.nameRequired)
        #expect(model.nameFocusRequest == 1)
        model.name = "Drill"
        #expect(model.nameError == nil)
        var bad = model.values
        bad.quantity = "x"
        model.edit(bad)
        await model.save(andAnother: false)
        #expect(model.nameError == nil)
        #expect(await harness.items.creates.isEmpty)
    }

    @Test("an item for a container deleted elsewhere is saved in the drop zone")
    func goneContainer() async {
        let (spaces, containers) = Self.garage()
        let harness = Harness(spaces: spaces, containers: containers)
        let model = harness.makeModel(AddParams(containerId: "deleted-elsewhere"))
        await model.loadPlaces()
        #expect(model.place.isDropZone)
        model.name = "Drill"
        await model.save(andAnother: false)
        #expect(await harness.items.creates.first?.containerId == DropZone.containerId)
        #expect(harness.toasts.last?.message == "Saved in the drop zone.")
        #expect(RecentPlacesStore(preferences: harness.preferences).read() == [])
    }

    @Test("a refreshed suggestion is reported as accepted and hinted")
    func hintedTelemetry() async {
        let harness = Harness(recognizer: EntitiesRecognizer([Self.found("Drill"), Self.found("Grinder")]))
        let model = harness.makeModel(AddParams(photoUri: "file:///p.webp"))
        model.start()
        await model.recognitionTask?.value
        model.name = "Angle grinder"
        model.refreshSuggestion()
        await model.recognitionTask?.value
        await model.save(andAnother: false)
        #expect(harness.telemetry.events.first?.payload == ["hasPhoto": .bool(true), "suggestionAccepted": .bool(true), "hinted": .bool(true)])
    }

    // MARK: Leaving

    @Test("Cancel asks before discarding, then deletes the photo and forgets the draft")
    func cancelDiscards() async {
        let harness = Harness(confirm: SharedSeamsConfirmScript(answers: [false, true]))
        let model = harness.makeModel(AddParams(photoUri: "file:///p.webp", photoThumbUri: "file:///t.webp"))
        model.start()
        model.name = "Drill"

        await model.cancel()
        #expect(harness.confirm.asked.count == 1)
        #expect(harness.screen.closes == 0)
        #expect(harness.photos.deleted.isEmpty)

        await model.cancel()
        let asked = harness.confirm.asked.last
        #expect(asked == ConfirmOptions(title: L10n.Add.discardTitle, body: L10n.Add.discardBody, confirmLabel: L10n.Forms.discard, cancelLabel: L10n.Forms.keepEditing))
        #expect(harness.photos.deleted == [["file:///p.webp", "file:///t.webp"]])
        #expect(harness.drafts.restorableDraft(now: harness.now) == nil)
        #expect(harness.screen.closes == 1)
    }

    @Test("Cancel with nothing typed closes at once and leaves another sheet's draft")
    func cancelEmpty() async {
        let harness = Harness()
        let first = harness.makeModel(owner: "first")
        first.start()
        first.name = "Torch"
        first.sheetClosed()

        let second = harness.makeModel(AddParams(containerId: "chest"), owner: "second")
        second.start()
        await second.cancel()
        #expect(harness.confirm.asked.isEmpty)
        #expect(harness.screen.closes == 1)
        #expect(harness.drafts.restorableDraft(now: harness.now)?.state.values.name == "Torch")
    }

    @Test("Snap several replaces the sheet with Quick Snap and keeps the draft")
    func snapSeveral() {
        let harness = Harness()
        let model = harness.makeModel(AddParams(containerId: "chest"))
        model.start()
        model.name = "Torch"
        model.snapSeveral()
        #expect(harness.camera.replacements.map(\.containerId) == ["chest"])
        #expect(harness.camera.replacements.map(\.fast) == [true])
        #expect(harness.drafts.restorableDraft(now: harness.now)?.state.values.name == "Torch")
    }

    @Test("an answer arriving after the sheet was swiped away changes nothing, so the draft restarts it")
    func lateAnswerAfterClose() async {
        let recognizer = EntitiesRecognizer([Self.found("Drill")])
        await recognizer.setHold(true)
        let harness = Harness(recognizer: recognizer)
        let model = harness.makeModel(AddParams(photoUri: "file:///p.webp"))
        model.start()
        await EntitiesRecognizer.waitForHeld(recognizer, count: 1)
        model.sheetClosed()
        await recognizer.release()
        await model.recognitionTask?.value
        let draft = harness.drafts.restorableDraft(now: harness.now)
        #expect(draft?.state.suggestion == .running)
        #expect(draft?.state.values.name == "")
        // The next plain open restarts the cut-off recognition.
        let next = harness.makeModel(owner: "next")
        #expect(next.initial.recognize)
    }

    @Test("while saving, the sheet resists a swipe and ignores a second save, Cancel, the place step and the photo options")
    func whileSaving() async {
        let items = EntitiesFakeItems()
        await items.setHoldCreates(true)
        let harness = Harness(items: items, confirm: SharedSeamsConfirmScript(answers: [true]))
        let model = harness.makeModel(AddParams(photoUri: "file:///p.webp"))
        model.name = "Drill"
        #expect(!model.interactiveDismissDisabled)
        #expect(model.canShowPhotoOptions)

        let saving = Task { await model.save(andAnother: false) }
        await EntitiesFakeItems.waitForHeld(items, count: 1)
        #expect(model.saving == .save)
        #expect(model.interactiveDismissDisabled)
        #expect(!model.canShowPhotoOptions)
        await model.save(andAnother: true)
        await model.cancel()
        model.showPlaceStep()
        model.snapSeveral()
        model.clearRestored()
        await model.takePhoto()
        // The photo files are being written into the item: removing or retaking does nothing.
        model.removePhoto()
        await model.retakePhoto()
        #expect(await items.creates.count == 1)
        #expect(harness.confirm.asked.isEmpty)
        #expect(!model.isPickingPlace)
        #expect(harness.camera.replacements.isEmpty)
        #expect(harness.camera.opened.isEmpty)
        #expect(model.photo != nil)
        #expect(harness.photos.deleted.isEmpty)

        await items.releaseNextUpdate()
        await saving.value
        #expect(harness.screen.closes == 1)
    }
}

/// The camera as the Add sheet sees it: photos it hands back, and how it was opened.
@MainActor
final class EntitiesCameraStub {
    var photos: [StoredImage] = []
    var opened: [String] = []
    var replacements: [(containerId: String, fast: Bool)] = []
}
