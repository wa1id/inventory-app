import Foundation
import InventoryCore
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

// New container (app/container/new.tsx; 07 §3.6): a box by default, no validation, the opener's
// request answered before the sheet closes, and the space's read never blocking Create.

@Suite("New container (container/new.tsx)")
@MainActor
struct PlacesContainerNewModelTests {
    private let seams = PlacesSeams()
    private let screen = PlacesScreenStub<ContainerNewModel.Navigation>()

    private func makeModel(
        spaces: PlacesFakeSpaces = PlacesFakeSpaces(),
        containers: PlacesFakeContainers,
        request: RouteRequest<NewContainerResult>? = nil,
        results: RouteResults? = nil
    ) -> ContainerNewModel {
        ContainerNewModel(
            spaceId: "garage",
            request: request,
            routeResults: results,
            spaces: spaces,
            containers: containers,
            invalidator: seams.invalidations,
            toasts: seams.toasts,
            confirm: seams.confirm,
            haptics: seams.haptics.player,
            telemetry: seams.reporter,
            isFocused: screen.isFocused,
            navigate: screen.navigate
        )
    }

    @Test("creates a box by default with the name as typed, and opens it when nobody waits")
    func createsAndOpens() async {
        let containers = PlacesFakeContainers()
        await containers.set(create: .value(PlacesFixtures.container(id: "c-new", name: "Paint", visualType: .box, shortCode: "BOX-2AAA")))
        let model = makeModel(containers: containers)
        model.setName(" Paint ")

        await model.save()

        #expect(await containers.creates == [CreateContainerInput(spaceId: "garage", name: " Paint ", visualType: .box)])
        #expect(seams.telemetry.names == ["container_created"])
        #expect(seams.invalidations.count == 1)
        #expect(seams.haptics.played == [.success])
        #expect(screen.navigations == [.openContainer(id: "c-new")])
    }

    @Test("a blank name makes an unnamed container: there is no validation")
    func blankNameCreates() async {
        let containers = PlacesFakeContainers()
        let model = makeModel(containers: containers)
        model.setVisualType(.drawer)

        await model.save()

        #expect(await containers.creates == [CreateContainerInput(spaceId: "garage", name: "", visualType: .drawer)])
        #expect(model.failure == nil)
    }

    @Test("hands the container to a waiting picker and closes the sheet instead of opening it")
    func deliversToThePicker() async throws {
        let containers = PlacesFakeContainers()
        let made = PlacesFixtures.container(id: "c-shelf", name: nil, visualType: .shelf, shortCode: "SHF-7QQQ")
        await containers.set(create: .value(made))
        let results = RouteResults()
        let opener = PlacesOpener<NewContainerResult>()
        await opener.open(results)
        let model = makeModel(containers: containers, request: opener.request, results: results)
        model.setVisualType(.shelf)

        await model.save()
        // The sheet closed in the same step as the delivery: before the picker resumed.
        #expect(screen.navigations == [.close])
        #expect(opener.answer == nil)
        await opener.waitForAnswer()

        #expect(opener.answer == .some(NewContainerResult(made)))
        #expect(results.isPending(opener.request) == false)
    }

    @Test("a request nobody waits for any more opens the container itself")
    func abandonedRequestOpens() async {
        let containers = PlacesFakeContainers()
        let results = RouteResults()
        let opener = PlacesOpener<NewContainerResult>()
        await opener.open(results)
        results.abandon(opener.request)
        let model = makeModel(containers: containers, request: opener.request, results: results)

        await model.save()

        #expect(screen.navigations == [.openContainer(id: "new-box")])
    }

    @Test("the space's line shows once it is read; a failed read still leaves the form working")
    func contextLine() async {
        let spaces = PlacesFakeSpaces()
        await spaces.set(byId: .value(PlacesFixtures.space(name: "Garage")))
        let containers = PlacesFakeContainers()
        let model = makeModel(spaces: spaces, containers: containers)
        #expect(model.contextLine == nil)
        #expect(!model.isSpaceGone)

        model.focusChanged(true, revision: 0)
        await placesSettle(model.space)
        #expect(model.contextLine == "In Garage")

        await spaces.set(byId: .failure(PlacesFailure()))
        let failing = makeModel(spaces: spaces, containers: containers)
        failing.focusChanged(true, revision: 0)
        await placesSettle(failing.space)
        #expect(failing.contextLine == nil)
        #expect(!failing.isSpaceGone)
        await failing.save()
        #expect(await containers.creates.count == 1)
    }

    @Test("a space found gone has nothing to add to; never while it loads")
    func spaceGone() async {
        let spaces = PlacesFakeSpaces()
        let model = makeModel(spaces: spaces, containers: PlacesFakeContainers())
        model.focusChanged(true, revision: 0)
        #expect(!model.isSpaceGone)
        await placesSettle(model.space)
        #expect(model.isSpaceGone)
        // A refresh in flight is not "gone" yet.
        model.space.reload()
        #expect(!model.isSpaceGone)
        await placesSettle(model.space)
    }

    @Test("a failed create shows the notice with the container's words; typing or a type clears it")
    func failedCreate() async throws {
        let containers = PlacesFakeContainers()
        await containers.set(create: .failure(HouseholdHttpError(status: 404, code: "not_found")))
        let model = makeModel(containers: containers)

        await model.save()
        let notice = try #require(model.notice)
        #expect(notice.title == L10n.Errors.Gone.container)
        #expect(!model.isSaving)
        #expect(seams.haptics.played == [.error])

        model.setName("P")
        #expect(model.notice == nil)
        await model.save()
        #expect(model.notice != nil)
        model.setVisualType(.bag)
        #expect(model.notice == nil)
    }

    @Test("closed under the save: the toast names it by its code when unnamed; a failure says it was not added")
    func closedMidSave() async {
        let containers = PlacesFakeContainers()
        let gate = PlacesGate()
        await containers.set(gate: gate)
        let model = makeModel(containers: containers)

        let saving = Task { await model.save() }
        await gate.waitForArrivals(1)
        screen.focused = false
        await gate.open()
        await saving.value
        #expect(screen.navigations.isEmpty)
        #expect(seams.toasts.messages == ["BOX-9QQX was added."])

        let failing = PlacesFakeContainers()
        await failing.set(create: .failure(placesOffline))
        let other = makeModel(containers: failing)
        await other.save()
        #expect(other.notice == nil)
        #expect(seams.toasts.messages.last == "The container was not added. Check the connection and try again.")
    }

    @Test("dirty when a name is typed or the type changed; one save at a time")
    func dirtyAndOneAtATime() async {
        let containers = PlacesFakeContainers()
        let gate = PlacesGate()
        await containers.set(gate: gate)
        let model = makeModel(containers: containers)
        #expect(!model.isDirty)
        model.setName("   ")
        #expect(!model.isDirty)
        model.setName("Paint")
        #expect(model.dirtyGuard.dirty)
        model.setName("")
        model.setVisualType(.crate)
        #expect(model.dirtyGuard.dirty)

        let first = Task { await model.save() }
        await gate.waitForArrivals(1)
        #expect(model.isSaving)
        #expect(model.dirtyGuard.saving)
        await model.save()
        await gate.open()
        await first.value
        #expect(await containers.creates.count == 1)
    }
}
