import Foundation
import InventoryCore
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

// Edit space (app/space/[id]/edit.tsx; 07 §3.13): seeding once, Save with every field and no
// dirty gate, a space gone elsewhere never read as success, and Delete asking what goes with it.

@Suite("Edit space (space/[id]/edit.tsx)")
@MainActor
struct PlacesSpaceEditModelTests {
    private let screen = PlacesScreenStub<SpaceEditModel.Navigation>()
    private static let garage = PlacesFixtures.space(id: "garage", name: "Garage", icon: "🧰", color: "#5B8DEF")

    private func makeModel(
        _ spaces: PlacesFakeSpaces,
        containers: PlacesFakeContainers = PlacesFakeContainers(),
        seams: PlacesSeams
    ) -> SpaceEditModel {
        SpaceEditModel(
            id: "garage",
            spaces: spaces,
            containers: containers,
            photos: seams.photos,
            invalidator: seams.invalidations,
            toasts: seams.toasts,
            confirm: seams.confirm,
            haptics: seams.haptics.player,
            telemetry: seams.reporter,
            isFocused: screen.isFocused,
            navigate: screen.navigate
        )
    }

    private func loaded(
        _ spaces: PlacesFakeSpaces,
        containers: PlacesFakeContainers = PlacesFakeContainers(),
        seams: PlacesSeams
    ) async -> SpaceEditModel {
        await spaces.set(byId: .value(Self.garage))
        let model = makeModel(spaces, containers: containers, seams: seams)
        model.focusChanged(true, revision: 0)
        await placesSettle(model.space, model.counts)
        return model
    }

    @Test("seeds the form once from the stored space; a later read never overwrites typing")
    func seedsOnce() async {
        let seams = PlacesSeams()
        let spaces = PlacesFakeSpaces()
        let model = await loaded(spaces, seams: seams)
        #expect(model.values == SpaceFormValues(name: "Garage", icon: "🧰", color: "#5B8DEF"))
        #expect(!model.isDirty)
        #expect(model.previewFallbackName == "Garage")

        model.change(SpaceFormValues(name: "Workshop", icon: "🧰", color: "#5B8DEF"))
        #expect(model.isDirty)
        #expect(model.dirtyGuard.dirty)
        await spaces.set(byId: .value(PlacesFixtures.space(id: "garage", name: "Garage (theirs)")))
        model.revisionChanged(1)
        await placesSettle(model.space)

        #expect(model.stored?.name == "Garage (theirs)")
        #expect(model.values.name == "Workshop")
    }

    @Test("the preview shows the space's counts, and no preview while they load")
    func previewCounts() async {
        let seams = PlacesSeams()
        let spaces = PlacesFakeSpaces()
        await spaces.set(list: .value([
            PlacesFixtures.spaceRow(PlacesFixtures.space(id: "attic", name: "Attic"), containers: 9, items: 9),
            PlacesFixtures.spaceRow(Self.garage, containers: 3, items: 5),
        ]))
        let unread = makeModel(spaces, seams: seams)
        #expect(unread.previewMeta == nil)

        let model = await loaded(spaces, seams: seams)
        #expect(model.previewMeta == "3 containers and 5 items")
    }

    @Test("states before the form: loading, a failed read with its cause, and a space found gone")
    func blockingStates() async {
        let seams = PlacesSeams()
        let spaces = PlacesFakeSpaces()
        let model = makeModel(spaces, seams: seams)
        guard case .loading? = model.blocking else {
            Issue.record("expected loading before the first read")
            return
        }

        await spaces.set(byId: .failure(PlacesFailure()))
        model.focusChanged(true, revision: 0)
        await placesSettle(model.space)
        guard case .failed? = model.blocking else {
            Issue.record("expected the failed read")
            return
        }

        await spaces.set(byId: .value(nil))
        model.space.reload()
        await placesSettle(model.space)
        guard case .gone? = model.blocking else {
            Issue.record("expected gone")
            return
        }
    }

    @Test("Save with a blank name asks for one and writes nothing")
    func blankName() async {
        let seams = PlacesSeams()
        let spaces = PlacesFakeSpaces()
        let model = await loaded(spaces, seams: seams)
        model.change(SpaceFormValues(name: "  ", icon: "🧰", color: "#5B8DEF"))

        await model.save()

        #expect(model.nameError == "Give the space a name.")
        #expect(model.nameFocusRequests == 1)
        #expect(await spaces.updates.isEmpty)
    }

    @Test("saves all three fields with the trimmed name, closes and says so, with no haptic")
    func saves() async {
        let seams = PlacesSeams()
        let spaces = PlacesFakeSpaces()
        let model = await loaded(spaces, seams: seams)
        model.change(SpaceFormValues(name: " Workshop ", icon: "🚗", color: "#E4572E"))

        await model.save()

        #expect(await spaces.updates == [UpdateSpaceInput(name: "Workshop", icon: "🚗", color: "#E4572E")])
        #expect(seams.telemetry.names == ["space_updated"])
        #expect(seams.invalidations.count == 1)
        #expect(screen.navigations == [.close])
        #expect(seams.toasts.messages == ["Changes saved."])
        #expect(seams.haptics.played.isEmpty)
    }

    @Test("Save is not gated on a change: an unchanged save still writes")
    func unchangedSaveWrites() async {
        let seams = PlacesSeams()
        let spaces = PlacesFakeSpaces()
        let model = await loaded(spaces, seams: seams)

        await model.save()

        #expect(await spaces.updates == [UpdateSpaceInput(name: "Garage", icon: "🧰", color: "#5B8DEF")])
    }

    @Test("closed under the save: no navigation, but the toast still says it saved")
    func closedMidSave() async {
        let seams = PlacesSeams()
        let spaces = PlacesFakeSpaces()
        let gate = PlacesGate()
        let model = await loaded(spaces, seams: seams)
        await spaces.set(gate: gate)

        let saving = Task { await model.save() }
        await gate.waitForArrivals(1)
        screen.focused = false
        await gate.open()
        await saving.value

        #expect(screen.navigations.isEmpty)
        #expect(seams.toasts.messages == ["Changes saved."])
    }

    @Test("a save that finds the space gone is never a fake success: the gone notice, Save and Delete off")
    func goneOnSave() async throws {
        let seams = PlacesSeams()
        let spaces = PlacesFakeSpaces()
        let model = await loaded(spaces, seams: seams)
        await spaces.set(update: .value(nil))
        model.change(SpaceFormValues(name: "Workshop", icon: "🧰", color: "#5B8DEF"))

        await model.save()

        #expect(model.isGone)
        let notice = try #require(model.notice)
        #expect(notice.title == L10n.Errors.Gone.space)
        #expect(model.isSaveDisabled && model.isDeleteDisabled)
        #expect(!model.isDirty)
        #expect(!model.dirtyGuard.guarded)
        #expect(seams.haptics.played == [.error])
        #expect(seams.telemetry.names.isEmpty)
        #expect(screen.navigations.isEmpty)

        // Typing keeps the gone notice.
        model.change(SpaceFormValues(name: "Workshop 2", icon: "🧰", color: "#5B8DEF"))
        #expect(model.isGone)
    }

    @Test("a failed save keeps the form; the next change clears the notice")
    func failedSave() async {
        let seams = PlacesSeams()
        let spaces = PlacesFakeSpaces()
        let model = await loaded(spaces, seams: seams)
        await spaces.set(update: .failure(PlacesFailure()))
        model.change(SpaceFormValues(name: "Workshop", icon: "🧰", color: "#5B8DEF"))

        await model.save()

        #expect(model.notice?.message == "It was not saved. Try again.")
        #expect(model.busy == nil)
        #expect(model.values.name == "Workshop")
        model.change(SpaceFormValues(name: "Workshop", icon: "🚗", color: "#5B8DEF"))
        #expect(model.notice == nil)
    }

    @Test("closed under a failed save: the toast names the stored space, or says it was already deleted")
    func closedMidFailedSave() async {
        for (answer, expected) in [
            (PlacesAnswer<Space?>.failure(placesOffline), "Changes to Garage were not saved. Check the connection and try again."),
            (PlacesAnswer<Space?>.value(nil), "Garage was already deleted, probably on another phone."),
        ] {
            let seams = PlacesSeams()
            let spaces = PlacesFakeSpaces()
            let gate = PlacesGate()
            let model = await loaded(spaces, seams: seams)
            screen.focused = true
            await spaces.set(update: answer, gate: gate)
            model.change(SpaceFormValues(name: "Workshop", icon: "🧰", color: "#5B8DEF"))

            let saving = Task { await model.save() }
            await gate.waitForArrivals(1)
            screen.focused = false
            await gate.open()
            await saving.value

            #expect(seams.toasts.messages == [expected])
            #expect(seams.toasts.last?.tone == .error)
            #expect(model.notice == nil)
        }
    }

    @Test("Delete asks first, counting labels from the containers when the impact has none (paired)")
    func deleteAsksFirst() async throws {
        let seams = PlacesSeams(confirmAnswers: [false])
        let spaces = PlacesFakeSpaces()
        let containers = PlacesFakeContainers()
        await spaces.set(impact: .value(SpaceDeletionImpact(containerCount: 3, itemCount: 21, photoCount: 0, qrBindingCount: 0)))
        await containers.set(bySpace: .value([
            PlacesFixtures.containerRow(PlacesFixtures.container(id: "a"), qrToken: "t1"),
            PlacesFixtures.containerRow(PlacesFixtures.container(id: "b")),
            PlacesFixtures.containerRow(PlacesFixtures.container(id: "c"), qrToken: "t2"),
        ]))
        let model = await loaded(spaces, containers: containers, seams: seams)

        await model.delete()

        let asked = try #require(seams.confirm.asked.first)
        #expect(asked.title == "Delete Garage?")
        #expect(asked.body == "This also deletes 3 containers and 21 items, and unlinks 2 QR labels. This cannot be undone.")
        #expect(asked.confirmLabel == "Delete")
        #expect(asked.destructive)
        // Cancelled: nothing deleted, and the form is free again.
        #expect(await spaces.deletes.isEmpty)
        #expect(model.busy == nil)
        #expect(screen.navigations.isEmpty)
    }

    @Test("Delete confirmed: deletes, removes the orphaned photos, logs, goes to Spaces and says so")
    func deletes() async {
        let seams = PlacesSeams(confirmAnswers: [true])
        let spaces = PlacesFakeSpaces()
        await spaces.set(
            impact: .value(SpaceDeletionImpact(containerCount: 1, itemCount: 2, photoCount: 1, qrBindingCount: 0)),
            delete: .value(DeletionResult(deleted: true, orphanedPhotoUris: ["file:///a.webp", "file:///a-thumb.webp"]))
        )
        let model = await loaded(spaces, seams: seams)

        await model.delete()

        #expect(await spaces.deletes == ["garage"])
        #expect(seams.photos.deleted == [["file:///a.webp", "file:///a-thumb.webp"]])
        #expect(seams.telemetry.events == [RecordingTelemetry.Entry(level: "event", name: "space_deleted", payload: ["containerCount": .int(1), "itemCount": .int(2)])])
        #expect(seams.invalidations.count == 1)
        #expect(screen.navigations == [.goToSpaces])
        #expect(seams.toasts.messages == ["Garage was deleted."])
        // No haptic on a successful delete (08 §7.2).
        #expect(seams.haptics.played.isEmpty)
    }

    @Test("a delete that found nothing says it was already deleted, and neither logs nor deletes photos")
    func alreadyDeleted() async {
        let seams = PlacesSeams(confirmAnswers: [true])
        let spaces = PlacesFakeSpaces()
        await spaces.set(delete: .value(.notDeleted))
        let model = await loaded(spaces, seams: seams)

        await model.delete()

        #expect(seams.photos.deleted.isEmpty)
        #expect(seams.telemetry.names.isEmpty)
        #expect(screen.navigations == [.goToSpaces])
        #expect(seams.toasts.messages == ["Garage was already deleted, probably on another phone."])
    }

    @Test("a delete that failed at any step keeps the space and says so")
    func deleteFails() async {
        let seams = PlacesSeams(confirmAnswers: [true])
        let spaces = PlacesFakeSpaces()
        await spaces.set(delete: .failure(placesOffline))
        let model = await loaded(spaces, seams: seams)

        await model.delete()
        #expect(seams.toasts.messages == ["Garage was not deleted. Check the connection and try again."])
        #expect(seams.toasts.last?.tone == .error)
        #expect(seams.haptics.played == [.error])
        #expect(model.busy == nil)
        #expect(screen.navigations.isEmpty)

        // The impact read failing is told the same way, before anything is asked.
        let seams2 = PlacesSeams()
        await spaces.set(impact: .failure(PlacesFailure()))
        let model2 = await loaded(spaces, seams: seams2)
        await model2.delete()
        #expect(seams2.confirm.asked.isEmpty)
        #expect(seams2.toasts.messages == ["Garage was not deleted. Try again."])
    }

    @Test("Save and Delete lock each other out while one runs")
    func busyLocks() async {
        let seams = PlacesSeams()
        let spaces = PlacesFakeSpaces()
        let gate = PlacesGate()
        let model = await loaded(spaces, seams: seams)
        await spaces.set(gate: gate)

        let saving = Task { await model.save() }
        await gate.waitForArrivals(1)
        #expect(model.isSaving)
        #expect(model.isDeleteDisabled)
        #expect(!model.isSaveDisabled)
        #expect(model.dirtyGuard.saving)
        await model.delete()
        #expect(seams.confirm.asked.isEmpty)
        await gate.open()
        await saving.value
    }
}
