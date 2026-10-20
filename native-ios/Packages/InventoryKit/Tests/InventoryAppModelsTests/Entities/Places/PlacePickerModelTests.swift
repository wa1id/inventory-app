import Foundation
import InventoryCore
import InventoryStorage
import InventoryStrings
import Synchronization
import Testing
@testable import InventoryAppModels

// The place picker's model (src/ui/components/PlacePicker.tsx:110-288; 07 §4.1). RN has no tests
// for the component; these pin the reads, the loading and failure rules, the pick and the
// inline create flows the spec lists, plus src/hooks/__tests__/useRecentPlaces.test.tsx.

/// What a read answers next: its rows, or a failure.
private final class EntitiesPlacePickerReadScript: Sendable {
    struct Failure: Error, Equatable { let name: String }

    private let containers = Mutex<Result<[ContainerWithSpace], Failure>>(.success([]))
    private let spaces = Mutex<Result<[SpaceWithCounts], Failure>>(.success([]))
    private let calls = Mutex<[String]>([])

    var log: [String] { calls.withLock { $0 } }

    func answer(containers: Result<[ContainerWithSpace], Failure>) { self.containers.withLock { $0 = containers } }
    func answer(spaces: Result<[SpaceWithCounts], Failure>) { self.spaces.withLock { $0 = spaces } }

    var reads: PlacePickerModel.Reads {
        PlacePickerModel.Reads(
            containers: { [self] in
                calls.withLock { $0.append("containers") }
                return try containers.withLock { $0 }.get()
            },
            spaces: { [self] in
                calls.withLock { $0.append("spaces") }
                return try spaces.withLock { $0 }.get()
            }
        )
    }
}

/// A form the test answers by hand, to hold it open.
@MainActor
private final class EntitiesPlacePickerFormGate<Value: Sendable> {
    private(set) var opened: [String] = []
    private var waiting: CheckedContinuation<Value?, Never>?

    var isOpen: Bool { waiting != nil }

    func open(_ label: String) async -> Value? {
        opened.append(label)
        return await withCheckedContinuation { waiting = $0 }
    }

    func answer(_ value: Value?) {
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: value)
    }

    func waitUntilOpen() async {
        while waiting == nil { await Task.yield() }
    }
}

@Suite("PlacePicker model (PlacePicker.tsx)")
@MainActor
struct EntitiesPlacePickerModelTests {
    private static let garage = SpaceWithCounts(
        space: Space(id: "garage", name: "Garage", icon: "🧰", color: "#5B8DEF", createdAt: 1, updatedAt: 1),
        containerCount: 1, itemCount: 2)
    private static let chest = ContainerWithSpace(
        container: Container(id: "chest", spaceId: "garage", name: "Tool chest", visualType: .cabinet, shortCode: "CAB-J92R", createdAt: 1, updatedAt: 1),
        spaceName: "Garage", itemCount: 2)
    private static let bin = ContainerWithSpace(
        container: Container(id: "bin", spaceId: "garage", name: "Red bin", visualType: .bin, shortCode: "BIN-4F2A", createdAt: 1, updatedAt: 1),
        spaceName: "Garage", itemCount: 0)

    private func recent(_ ids: [String], preferences: InMemoryPreferences = InMemoryPreferences()) -> RecentPlacesModel {
        let store = RecentPlacesStore(preferences: preferences)
        for id in ids.reversed() { store.remember(id) }
        return RecentPlacesModel(store: store)
    }

    private func makeModel(
        mode: PlacePickerMode = .move,
        allowsNewContainer: Bool? = nil,
        script: EntitiesPlacePickerReadScript = EntitiesPlacePickerReadScript(),
        recentIds: [String] = [],
        forms: PlacePickerModel.Forms = .none,
        haptics: SharedSeamsHapticRecorder = SharedSeamsHapticRecorder(),
        onPick: @escaping @MainActor (PickedPlace) -> Void = { _ in }
    ) -> PlacePickerModel {
        PlacePickerModel(
            mode: mode,
            allowsNewContainer: allowsNewContainer,
            reads: script.reads,
            recentPlaces: recent(recentIds),
            forms: forms,
            haptics: haptics.player,
            onPick: onPick
        )
    }

    /// Waits for both reads to settle.
    private func settle(_ model: PlacePickerModel) async {
        await model.containers.readTask?.value
        await model.spaces.readTask?.value
    }

    private func loaded(
        _ script: EntitiesPlacePickerReadScript,
        mode: PlacePickerMode = .move,
        forms: PlacePickerModel.Forms = .none,
        haptics: SharedSeamsHapticRecorder = SharedSeamsHapticRecorder(),
        onPick: @escaping @MainActor (PickedPlace) -> Void = { _ in }
    ) async -> PlacePickerModel {
        script.answer(containers: .success([Self.chest, Self.bin]))
        script.answer(spaces: .success([Self.garage]))
        let model = makeModel(mode: mode, script: script, forms: forms, haptics: haptics, onPick: onPick)
        model.focusChanged(true, revision: 0)
        await settle(model)
        return model
    }

    // MARK: Mode defaults

    @Test("New container is offered everywhere but open, unless the screen says otherwise", arguments: [
        (PlacePickerMode.move, true), (.file, true), (.choose, true), (.bind, true), (.open, false),
    ])
    func modeDefaults(mode: PlacePickerMode, allowsNew: Bool) {
        #expect(makeModel(mode: mode).allowsNewContainer == allowsNew)
        #expect(makeModel(mode: mode, allowsNewContainer: !allowsNew).allowsNewContainer == !allowsNew)
        let model = makeModel(mode: mode)
        #expect(!model.showsDropZone)
        #expect(model.busyId == nil && model.query.isEmpty && model.selectedContainerId == nil)
    }

    @Test("the reads use the keys RN's queries used and run on the first focus")
    func readKeys() async {
        let script = EntitiesPlacePickerReadScript()
        let model = makeModel(script: script)
        #expect(model.containers.key == "containers-all")
        #expect(model.spaces.key == "spaces")
        #expect(script.log.isEmpty)
        model.focusChanged(true, revision: 3)
        await settle(model)
        #expect(Set(script.log) == ["containers", "spaces"])
    }

    // MARK: Loading and failure (PlacePicker.tsx:279-286)

    @Test("the skeleton shows until both lists have data")
    func loadingUntilBoth() async {
        let script = EntitiesPlacePickerReadScript()
        let model = makeModel(script: script)
        #expect(model.isLoading)
        #expect(model.failure == nil)
        script.answer(containers: .success([Self.chest]))
        script.answer(spaces: .success([Self.garage]))
        model.focusChanged(true)
        #expect(model.isLoading)
        await settle(model)
        #expect(!model.isLoading)
        #expect(model.failure == nil)
        #expect(model.options.map(\.id) == ["chest"])
        #expect(model.options.first?.spaceColor == "#5B8DEF")
    }

    @Test("a list with nothing to show fails the picker; the containers' cause wins", arguments: [
        // (containers fail, spaces fail, the failure shown)
        (true, false, "containers"),
        (false, true, "spaces"),
        (true, true, "containers"),
        (false, false, nil as String?),
    ])
    func failureTable(containersFail: Bool, spacesFail: Bool, shown: String?) async {
        let script = EntitiesPlacePickerReadScript()
        script.answer(containers: containersFail ? .failure(.init(name: "containers")) : .success([Self.chest]))
        script.answer(spaces: spacesFail ? .failure(.init(name: "spaces")) : .success([Self.garage]))
        let model = makeModel(script: script)
        model.focusChanged(true)
        await settle(model)
        #expect(!model.isLoading)
        #expect((model.failure as? EntitiesPlacePickerReadScript.Failure)?.name == shown)
    }

    @Test("a failed refresh keeps the lists on screen, and Try again reads both again")
    func refreshFailureKeepsData() async {
        let script = EntitiesPlacePickerReadScript()
        let model = await loaded(script)
        script.answer(containers: .failure(.init(name: "containers")))
        script.answer(spaces: .failure(.init(name: "spaces")))
        model.retry()
        #expect(!model.isLoading, "data on screen: no skeleton while reading again")
        await settle(model)
        #expect(model.failure == nil)
        #expect(model.containers.refreshFailed && model.spaces.refreshFailed)
        #expect(model.options.count == 2)
        #expect(script.log.filter { $0 == "containers" }.count == 2)
        #expect(script.log.filter { $0 == "spaces" }.count == 2)
    }

    @Test("loading wins over a failure while the other list still loads")
    func loadingBeforeFailure() async {
        let script = EntitiesPlacePickerReadScript()
        script.answer(containers: .failure(.init(name: "containers")))
        let model = makeModel(script: script)
        model.containers.reload()
        await model.containers.readTask?.value
        #expect(model.isLoading, "the spaces have not been read")
        #expect(model.failure != nil, "the view shows the skeleton first, then this")
    }

    // MARK: Empty and no match

    @Test("nothing at all: no containers, and none can be made (no spaces, or not offered)")
    func nothingAtAll() async {
        let script = EntitiesPlacePickerReadScript()
        let model = makeModel(mode: .file, script: script)
        #expect(!model.isNothingAtAll, "still loading")
        model.focusChanged(true)
        await settle(model)
        #expect(model.isNothingAtAll)

        script.answer(spaces: .success([Self.garage]))
        let withSpace = makeModel(mode: .file, script: script)
        withSpace.focusChanged(true)
        await settle(withSpace)
        #expect(!withSpace.isNothingAtAll, "New container in Garage is offered")
        #expect(withSpace.sections.map(\.id) == ["garage"])

        let open = makeModel(mode: .open, script: script)
        open.focusChanged(true)
        await settle(open)
        #expect(open.isNothingAtAll, "open mode offers no New container")
    }

    @Test("the filter narrows the sections and says when nothing matches")
    func filterAndNoMatch() async {
        let model = await loaded(EntitiesPlacePickerReadScript())
        model.query = "bin4f"
        #expect(model.sections.map(\.id) == ["garage"])
        #expect(model.sections.first?.entries.map(\.id) == ["space-bin", "new-garage"])
        #expect(model.noMatchMessage == nil)
        model.query = "  zzz "
        #expect(model.sections.map(\.kind) == [.new])
        #expect(model.noMatchMessage == L10n.Picker.noMatch(query: "zzz"))
    }

    // MARK: Recent places (useRecentPlaces.test.tsx)

    @Test("an open picker keeps its recent places when a pick remembers another; the next one sees it")
    func recentPlacesHeld() async {
        let preferences = InMemoryPreferences()
        let store = RecentPlacesStore(preferences: preferences)
        for id in ["c", "b", "a"] { store.remember(id) }
        let script = EntitiesPlacePickerReadScript()
        let open = PlacePickerModel(mode: .move, reads: script.reads, recentPlaces: RecentPlacesModel(store: store), forms: .none, haptics: { _ in }, onPick: { _ in })
        #expect(open.recentIds == ["a", "b", "c"])
        store.remember("b")
        #expect(open.recentIds == ["a", "b", "c"])
        let next = PlacePickerModel(mode: .move, reads: script.reads, recentPlaces: RecentPlacesModel(store: store), forms: .none, haptics: { _ in }, onPick: { _ in })
        #expect(next.recentIds == ["b", "a", "c"])
    }

    @Test("recent places show in recent order, up to four, only containers that exist")
    func recentSection() async {
        let script = EntitiesPlacePickerReadScript()
        let extra = (1...4).map { index in
            ContainerWithSpace(
                container: Container(id: "box\(index)", spaceId: "garage", name: "Box \(index)", visualType: .box, shortCode: "BOX-\(index)AAA", createdAt: 1, updatedAt: 1),
                spaceName: "Garage", itemCount: 0)
        }
        script.answer(containers: .success([Self.chest, Self.bin] + extra))
        script.answer(spaces: .success([Self.garage]))
        let model = makeModel(script: script, recentIds: ["bin", "gone", "box3", "chest", "box1", "box2"])
        model.focusChanged(true)
        await settle(model)
        let recent = model.sections.first { $0.kind == .recent }
        #expect(recent?.entries.map(\.id) == ["recent-bin", "recent-box3", "recent-chest", "recent-box1"])
    }

    // MARK: Pick

    @Test("a pick plays the choice haptic and hands the place to the screen; ignored while busy")
    func pick() async throws {
        let haptics = SharedSeamsHapticRecorder()
        var picked: [PickedPlace] = []
        let model = await loaded(EntitiesPlacePickerReadScript(), haptics: haptics) { picked.append($0) }
        let chest = try #require(model.options.first { $0.id == "chest" })
        model.pick(.dropZone)
        model.pick(.container(chest))
        #expect(picked.count == 2)
        #expect(haptics.played == [.choice, .choice])

        model.busyId = "chest"
        #expect(model.isBusy)
        model.pick(.dropZone)
        #expect(picked.count == 2)
        #expect(haptics.played.count == 2)
    }

    // MARK: Create inline (PlacePicker.tsx:211-265)

    @Test("New container picks what the form made, without reading it back or a haptic")
    func newContainerPicks() async throws {
        let haptics = SharedSeamsHapticRecorder()
        var picked: [PickedPlace] = []
        var asked: [String] = []
        let created = NewContainerResult(containerId: "new", name: "Paint shelf", shortCode: "SHF-3PQX", visualType: .shelf, spaceId: "garage")
        let forms = PlacePickerModel.Forms(
            createContainer: { asked.append($0); return created },
            createSpace: { nil },
            openNewSpace: {}
        )
        let script = EntitiesPlacePickerReadScript()
        let model = await loaded(script, forms: forms, haptics: haptics) { picked.append($0) }
        let readsBefore = script.log.count

        await model.newContainer(in: "garage", spaceName: "Garage")
        #expect(asked == ["garage"])
        let option = try #require(picked.first.flatMap { if case .container(let option) = $0 { option } else { nil } })
        #expect(option == PlaceOption(
            id: "new", name: "Paint shelf", shortCode: "SHF-3PQX", visualType: .shelf,
            spaceId: "garage", spaceName: "Garage", spaceColor: "#5B8DEF", spaceIcon: "🧰", itemCount: 0))
        #expect(haptics.played.isEmpty)
        #expect(script.log.count == readsBefore)
    }

    @Test("a form closed without a container picks nothing")
    func newContainerNil() async {
        var picked: [PickedPlace] = []
        let model = await loaded(EntitiesPlacePickerReadScript(), forms: .none) { picked.append($0) }
        await model.newContainer(in: "garage", spaceName: "Garage")
        #expect(picked.isEmpty)
    }

    @Test("New container is ignored while a pick saves")
    func newContainerBusy() async {
        var asked = 0
        let forms = PlacePickerModel.Forms(createContainer: { _ in asked += 1; return nil }, createSpace: { asked += 1; return nil }, openNewSpace: {})
        let model = await loaded(EntitiesPlacePickerReadScript(), forms: forms)
        model.busyId = DropZone.containerId
        await model.newContainer(in: "garage", spaceName: "Garage")
        await model.newSpace()
        #expect(asked == 0)
    }

    @Test("one form at a time: a second New container while the first is open does nothing")
    func openOnce() async {
        let gate = EntitiesPlacePickerFormGate<NewContainerResult>()
        var picked: [PickedPlace] = []
        let forms = PlacePickerModel.Forms(createContainer: { await gate.open($0) }, createSpace: { nil }, openNewSpace: {})
        let model = await loaded(EntitiesPlacePickerReadScript(), forms: forms) { picked.append($0) }

        let first = Task { await model.newContainer(in: "garage", spaceName: "Garage") }
        await gate.waitUntilOpen()
        await model.newContainer(in: "garage", spaceName: "Garage")
        await model.newSpace()
        #expect(gate.opened == ["garage"])

        gate.answer(NewContainerResult(containerId: "c1", name: nil, shortCode: "BOX-7K2M", visualType: .box, spaceId: "garage"))
        await first.value
        #expect(picked.count == 1)

        // Closed: the next one opens.
        let second = Task { await model.newContainer(in: "garage", spaceName: "Garage") }
        await gate.waitUntilOpen()
        #expect(gate.opened == ["garage", "garage"])
        gate.answer(nil)
        await second.value
        #expect(picked.count == 1)
    }

    @Test("no containers at all: a new space, then a container in it, and that is picked")
    func newSpaceThenContainer() async throws {
        var picked: [PickedPlace] = []
        var asked: [String] = []
        let forms = PlacePickerModel.Forms(
            createContainer: { spaceId in
                asked.append("container:\(spaceId)")
                return NewContainerResult(containerId: "c9", name: "Shoe box", shortCode: "BOX-9ZZZ", visualType: .box, spaceId: spaceId)
            },
            createSpace: {
                asked.append("space")
                return NewSpaceResult(spaceId: "hall", name: "Hall")
            },
            openNewSpace: { asked.append("open") }
        )
        let script = EntitiesPlacePickerReadScript()
        let model = makeModel(mode: .file, script: script, forms: forms) { picked.append($0) }
        model.focusChanged(true)
        await settle(model)
        #expect(model.isNothingAtAll)

        await model.newSpace()
        #expect(asked == ["space", "container:hall"])
        let option = try #require(picked.first.flatMap { if case .container(let option) = $0 { option } else { nil } })
        #expect(option.id == "c9")
        // The space is not in the list yet: its own name, no colour or icon.
        #expect(option.spaceName == "Hall")
        #expect(option.spaceColor.isEmpty && option.spaceIcon.isEmpty)
    }

    @Test("a new space form closed without a space opens no container form")
    func newSpaceNil() async {
        var asked: [String] = []
        let forms = PlacePickerModel.Forms(createContainer: { asked.append("container:\($0)"); return nil }, createSpace: { asked.append("space"); return nil }, openNewSpace: { asked.append("open") })
        let model = makeModel(mode: .choose, forms: forms)
        await model.newSpace()
        #expect(asked == ["space"])
    }

    @Test("where nothing waits for a place (open mode) the new space form opens and nothing is awaited")
    func newSpaceOpenMode() async {
        var asked: [String] = []
        var picked: [PickedPlace] = []
        let forms = PlacePickerModel.Forms(createContainer: { asked.append("container:\($0)"); return nil }, createSpace: { asked.append("space"); return nil }, openNewSpace: { asked.append("open") })
        let model = makeModel(mode: .open, forms: forms) { picked.append($0) }
        await model.newSpace()
        #expect(asked == ["open"])
        #expect(picked.isEmpty)
        // RN checks allowNewContainer, not the mode: a bind picker that offers no New container
        // opens the form the same way.
        let bind = makeModel(mode: .bind, allowsNewContainer: false, forms: forms)
        await bind.newSpace()
        #expect(asked == ["open", "open"])
    }
}
