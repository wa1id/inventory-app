import Foundation
import InventoryCore
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

// New space (app/space/new.tsx; 07 §3.11). RN has no tests for the screen; these pin the rules
// the spec lists: presets in one tap, the custom form, one guard for every way of saving, the
// opener's request, and a sheet closed under the save.

@Suite("New space (space/new.tsx)")
@MainActor
struct PlacesSpaceNewModelTests {
    private let seams = PlacesSeams()
    private let screen = PlacesScreenStub<SpaceNewModel.Navigation>()

    private func makeModel(
        _ spaces: PlacesFakeSpaces,
        request: RouteRequest<NewSpaceResult>? = nil,
        results: RouteResults? = nil
    ) -> SpaceNewModel {
        SpaceNewModel(
            request: request,
            routeResults: results,
            spaces: spaces,
            invalidator: seams.invalidations,
            toasts: seams.toasts,
            confirm: seams.confirm,
            haptics: seams.haptics.player,
            telemetry: seams.reporter,
            isFocused: screen.isFocused,
            navigate: screen.navigate
        )
    }

    private func loaded(_ spaces: PlacesFakeSpaces) async -> SpaceNewModel {
        let model = makeModel(spaces)
        model.focusChanged(true, revision: 0)
        await placesSettle(model.existing)
        return model
    }

    @Test("a preset creates the space at once and opens it when nobody waits")
    func presetOpensTheSpace() async throws {
        let spaces = PlacesFakeSpaces()
        await spaces.set(create: .value(PlacesFixtures.space(id: "s-garage", name: "Garage", icon: "🚗", color: "#5B8DEF")))
        let model = await loaded(spaces)
        let garage = try #require(SpacePalette.presets.first { $0.name == "Garage" })

        await model.pickPreset(garage)

        #expect(await spaces.creates == [CreateSpaceInput(name: "Garage", icon: "🚗", color: "#5B8DEF")])
        #expect(seams.telemetry.names == ["space_created"])
        #expect(seams.invalidations.count == 1)
        #expect(seams.haptics.played == [.success])
        #expect(screen.navigations == [.openSpace(id: "s-garage")])
        #expect(seams.toasts.shown.isEmpty)
    }

    @Test("hands the new space to a waiting picker and closes instead of opening it")
    func deliversToTheOpener() async throws {
        let spaces = PlacesFakeSpaces()
        await spaces.set(create: .value(PlacesFixtures.space(id: "s-hall", name: "Hall")))
        let results = RouteResults()
        let opener = PlacesOpener<NewSpaceResult>()
        await opener.open(results)
        let model = makeModel(spaces, request: opener.request, results: results)
        model.change(SpaceFormValues(name: "  Hall ", icon: "🚪", color: "#E0A800"))

        await model.createCustom()
        await opener.waitForAnswer()

        #expect(await spaces.creates == [CreateSpaceInput(name: "Hall", icon: "🚪", color: "#E0A800")])
        #expect(screen.navigations == [.close])
        #expect(opener.answer == .some(NewSpaceResult(spaceId: "s-hall", name: "Hall")))
    }

    @Test("a preset already added says so and creates nothing; the others stay available")
    func takenPreset() async throws {
        let spaces = PlacesFakeSpaces()
        await spaces.set(list: .value([PlacesFixtures.spaceRow(PlacesFixtures.space(name: " garage "))]))
        let model = await loaded(spaces)

        let tiles = Dictionary(uniqueKeysWithValues: model.presets.map { ($0.preset.name, $0) })
        let garage = try #require(tiles["Garage"])
        #expect(garage.isTaken)
        #expect(garage.isDisabled)
        #expect(!garage.isDimmed)
        #expect(garage.accessibilityLabel == "Garage. Already added.")
        #expect(garage.identifier == "space-preset-garage")
        let loft = try #require(tiles["Loft"])
        #expect(!loft.isTaken && !loft.isDisabled)
        #expect(loft.accessibilityLabel == "Loft. Creates the space straight away.")

        await model.pickPreset(garage.preset)
        #expect(await spaces.creates.isEmpty)
        #expect(screen.navigations.isEmpty)
    }

    @Test("while the spaces load, or after they failed, every preset is available")
    func presetsWhileTheListIsUnknown() async {
        let spaces = PlacesFakeSpaces()
        await spaces.set(list: .failure(PlacesFailure()))
        let unread = makeModel(spaces)
        #expect(unread.presets.allSatisfy { !$0.isTaken && !$0.isDisabled })

        let failed = await loaded(spaces)
        #expect(failed.existing.cause != nil)
        #expect(failed.presets.allSatisfy { !$0.isTaken && !$0.isDisabled })
    }

    @Test("Create with a blank name asks for one and focuses the field, writing nothing")
    func blankName() async {
        let spaces = PlacesFakeSpaces()
        let model = makeModel(spaces)
        model.change(SpaceFormValues(name: "   ", icon: SpacePalette.icons[0], color: SpacePalette.colors[0]))

        await model.createCustom()

        #expect(model.nameError == "Give the space a name.")
        #expect(model.nameFocusRequests == 1)
        #expect(await spaces.creates.isEmpty)
        #expect(seams.haptics.played.isEmpty)
    }

    @Test("a new name clears its error; any change clears a failed create's notice")
    func changesClearMessages() async {
        let spaces = PlacesFakeSpaces()
        await spaces.set(create: .failure(PlacesFailure()))
        let model = makeModel(spaces)
        await model.createCustom()
        #expect(model.nameError != nil)

        // The icon alone keeps the name's error.
        model.change(SpaceFormValues(name: "", icon: "🍳", color: SpacePalette.colors[0]))
        #expect(model.nameError != nil)
        model.change(SpaceFormValues(name: "Shed", icon: "🍳", color: SpacePalette.colors[0]))
        #expect(model.nameError == nil)

        await model.createCustom()
        #expect(model.notice != nil)
        model.change(SpaceFormValues(name: "Shed", icon: "🍳", color: SpacePalette.colors[1]))
        #expect(model.notice == nil)
    }

    @Test("one save at a time: the presets, the button and Return share one guard")
    func oneSaveAtATime() async throws {
        let spaces = PlacesFakeSpaces()
        let gate = PlacesGate()
        await spaces.set(gate: gate)
        let model = makeModel(spaces)
        model.change(SpaceFormValues(name: "Shed", icon: "🍳", color: "#2E9E4F"))
        let loft = try #require(SpacePalette.presets.first { $0.name == "Loft" })

        let first = Task { await model.pickPreset(loft) }
        await gate.waitForArrivals(1)
        #expect(model.saving == .preset("Loft"))
        let tiles = model.presets
        #expect(tiles.first { $0.preset.name == "Loft" }?.isBusy == true)
        #expect(tiles.first { $0.preset.name == "Garage" }.map { $0.isDisabled && $0.isDimmed } == true)
        #expect(model.isCreateDisabled)
        #expect(!model.isCreatingCustom)
        #expect(model.dirtyGuard.saving)

        await model.createCustom()
        await model.pickPreset(loft)
        #expect(await spaces.creates.count == 1)

        await gate.open()
        await first.value
        #expect(await spaces.creates.count == 1)
    }

    @Test("creates with the trimmed name; a custom name is not checked against existing ones")
    func customNameIsNotChecked() async {
        let spaces = PlacesFakeSpaces()
        await spaces.set(list: .value([PlacesFixtures.spaceRow(PlacesFixtures.space(name: "Garage"))]))
        let model = await loaded(spaces)
        model.change(SpaceFormValues(name: " Garage  ", icon: "🧰", color: "#0F9BB0"))

        await model.createCustom()

        #expect(await spaces.creates == [CreateSpaceInput(name: "Garage", icon: "🧰", color: "#0F9BB0")])
        #expect(model.isCreatingCustom)
    }

    @Test("a failed create keeps what was typed and shows why in the notice")
    func failedCreate() async throws {
        let spaces = PlacesFakeSpaces()
        await spaces.set(create: .failure(placesOffline))
        let model = makeModel(spaces)
        let typed = SpaceFormValues(name: "Shed", icon: "🍳", color: "#2E9E4F")
        model.change(typed)

        await model.createCustom()

        #expect(model.values == typed)
        #expect(model.saving == nil)
        #expect(seams.haptics.played == [.error])
        let notice = try #require(model.notice)
        #expect(notice.title == L10n.Errors.Offline.title)
        #expect(notice.message == L10n.Errors.Offline.save)
        #expect(seams.invalidations.count == 0)
        #expect(screen.navigations.isEmpty)
        #expect(seams.toasts.shown.isEmpty)
    }

    @Test("a local failure's notice has no title: its body says it all")
    func localFailureNotice() async throws {
        let spaces = PlacesFakeSpaces()
        await spaces.set(create: .failure(PlacesFailure()))
        let model = makeModel(spaces)
        model.change(SpaceFormValues(name: "Shed", icon: "🍳", color: "#2E9E4F"))

        await model.createCustom()

        let notice = try #require(model.notice)
        #expect(notice.title == nil)
        #expect(notice.message == "It was not saved. Try again.")
    }

    @Test("closed under the save: the space is still made and a toast says so, with no navigation")
    func closedMidSave() async {
        let spaces = PlacesFakeSpaces()
        let gate = PlacesGate()
        await spaces.set(create: .value(PlacesFixtures.space(id: "s-shed", name: "Shed")), gate: gate)
        let model = makeModel(spaces)
        model.change(SpaceFormValues(name: "Shed", icon: "🍳", color: "#2E9E4F"))

        let saving = Task { await model.createCustom() }
        await gate.waitForArrivals(1)
        screen.focused = false
        await gate.open()
        await saving.value

        #expect(screen.navigations.isEmpty)
        #expect(seams.toasts.messages == ["Shed was added."])
        #expect(seams.invalidations.count == 1)
        #expect(seams.haptics.played == [.success])
    }

    @Test("closed under a failed save: an error toast names the space instead of the notice")
    func closedMidFailedSave() async {
        let spaces = PlacesFakeSpaces()
        let gate = PlacesGate()
        await spaces.set(create: .failure(placesOffline), gate: gate)
        let model = makeModel(spaces)
        model.change(SpaceFormValues(name: " Shed ", icon: "🍳", color: "#2E9E4F"))

        let saving = Task { await model.createCustom() }
        await gate.waitForArrivals(1)
        screen.focused = false
        await gate.open()
        await saving.value

        #expect(model.notice == nil)
        #expect(seams.toasts.last?.tone == .error)
        #expect(seams.toasts.messages == ["Shed was not added. Check the connection and try again."])
    }

    @Test("the dirty guard counts typed changes only and never asks while saving")
    func dirtyGuard() async {
        let spaces = PlacesFakeSpaces()
        let gate = PlacesGate()
        await spaces.set(gate: gate)
        let model = makeModel(spaces)
        #expect(!model.dirtyGuard.dirty)

        model.change(SpaceFormValues(name: "  ", icon: SpacePalette.icons[0], color: SpacePalette.colors[0]))
        #expect(!model.dirtyGuard.dirty)
        model.change(SpaceFormValues(name: "", icon: SpacePalette.icons[0], color: SpacePalette.colors[2]))
        #expect(model.dirtyGuard.dirty)
        #expect(model.dirtyGuard.guarded)
        #expect(model.dirtyGuard.interactiveDismissDisabled)

        let saving = Task { await model.pickPreset(SpacePalette.presets[1]) }
        await gate.waitForArrivals(1)
        #expect(!model.dirtyGuard.guarded)
        #expect(await model.dirtyGuard.attemptClose())
        #expect(seams.confirm.asked.isEmpty)
        await gate.open()
        await saving.value
    }
}
