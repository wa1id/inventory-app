import Foundation
import InventoryCore
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

// Edit container (app/container/[id]/edit.tsx; 07 §3.8): seeding once (an unknown type kept),
// Save sending the raw name with no dirty gate, the gone case, the space list's three states,
// and Delete opening the space the container was stored in.

@Suite("Edit container (container/[id]/edit.tsx)")
@MainActor
struct PlacesContainerEditModelTests {
    private let screen = PlacesScreenStub<ContainerEditModel.Navigation>()
    private static let chest = PlacesFixtures.container(id: "chest", spaceId: "garage", name: "Tool chest", visualType: .cabinet, shortCode: "CAB-J92R")

    private func makeModel(
        _ containers: PlacesFakeContainers,
        spaces: PlacesFakeSpaces = PlacesFakeSpaces(),
        seams: PlacesSeams
    ) -> ContainerEditModel {
        ContainerEditModel(
            id: "chest",
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
        _ containers: PlacesFakeContainers,
        stored: Container = chest,
        spaces: PlacesFakeSpaces = PlacesFakeSpaces(),
        seams: PlacesSeams
    ) async -> ContainerEditModel {
        await containers.set(byId: .value(stored))
        let model = makeModel(containers, spaces: spaces, seams: seams)
        model.focusChanged(true, revision: 0)
        await placesSettle(model.container, model.spaces)
        return model
    }

    @Test("seeds once from the stored container; an unnamed one starts with an empty name")
    func seeds() async {
        let seams = PlacesSeams()
        let containers = PlacesFakeContainers()
        let model = await loaded(containers, stored: PlacesFixtures.container(name: nil, visualType: .bin, shortCode: "BIN-4F2A"), seams: seams)
        #expect(model.values == ContainerFormValues(name: "", visualType: .bin, spaceId: "garage"))
        #expect(model.label == "BIN-4F2A")
        #expect(model.codeAccessibilityLabel == "The label code stays B I N, 4 F 2 A, because it is printed on the label.")

        model.setName("Spares")
        await containers.set(byId: .value(PlacesFixtures.container(name: "Theirs", visualType: .bin)))
        model.revisionChanged(1)
        await placesSettle(model.container)
        #expect(model.values.name == "Spares")
    }

    @Test("a stored type this build does not know is kept and written back unchanged")
    func unknownTypeKept() async {
        let seams = PlacesSeams()
        let containers = PlacesFakeContainers()
        let model = await loaded(containers, stored: PlacesFixtures.container(visualType: "suitcase"), seams: seams)
        #expect(!ContainerVisualType.allKnown.contains(model.values.visualType))

        await model.save()

        #expect(await containers.updates == [UpdateContainerInput(name: .set("Tool chest"), visualType: "suitcase", spaceId: "garage")])
    }

    @Test("saves the name as typed with the type and space, closes and says so; not gated on a change")
    func saves() async {
        let seams = PlacesSeams()
        let containers = PlacesFakeContainers()
        let model = await loaded(containers, seams: seams)
        model.setName("  ")
        model.setVisualType(.crate)
        model.setSpace("attic")
        #expect(model.isDirty)

        await model.save()

        #expect(await containers.updates == [UpdateContainerInput(name: .set("  "), visualType: .crate, spaceId: "attic")])
        #expect(seams.telemetry.names == ["container_updated"])
        #expect(seams.invalidations.count == 1)
        #expect(screen.navigations == [.close])
        #expect(seams.toasts.messages == ["Changes saved."])
        #expect(seams.haptics.played.isEmpty)

        let again = await loaded(containers, seams: PlacesSeams())
        await again.save()
        #expect(await containers.updates.count == 2)
    }

    @Test("a container gone on save: the gone notice, Save and Delete off, and nothing to discard")
    func goneOnSave() async throws {
        let seams = PlacesSeams()
        let containers = PlacesFakeContainers()
        let model = await loaded(containers, seams: seams)
        await containers.set(update: .value(nil))
        model.setName("Renamed")

        await model.save()

        #expect(model.isGone)
        #expect(try #require(model.notice).title == L10n.Errors.Gone.container)
        #expect(model.isSaveDisabled && model.isDeleteDisabled)
        #expect(!model.dirtyGuard.guarded)
        #expect(seams.haptics.played == [.error])
        model.setVisualType(.bag)
        #expect(model.isGone)
    }

    @Test("closed under a failed save: the toast names it by its label")
    func closedMidFailedSave() async {
        for (answer, expected) in [
            (PlacesAnswer<Container?>.failure(PlacesFailure()), "Changes to Tool chest were not saved. Try again."),
            (PlacesAnswer<Container?>.value(nil), "Tool chest was already deleted, probably on another phone."),
        ] {
            let seams = PlacesSeams()
            let containers = PlacesFakeContainers()
            let gate = PlacesGate()
            let model = await loaded(containers, seams: seams)
            screen.focused = true
            await containers.set(update: answer, gate: gate)

            let saving = Task { await model.save() }
            await gate.waitForArrivals(1)
            screen.focused = false
            await gate.open()
            await saving.value

            #expect(seams.toasts.messages == [expected])
            #expect(model.notice == nil)
        }
    }

    @Test("the spaces to move to: the list, the failure in words with Try again, or the wait")
    func spaceChoice() async throws {
        let seams = PlacesSeams()
        let spaces = PlacesFakeSpaces()
        await spaces.set(list: .failure(placesOffline))
        let containers = PlacesFakeContainers()
        let unread = makeModel(containers, spaces: spaces, seams: seams)
        guard case .loading = unread.spaceChoice else {
            Issue.record("expected the wait")
            return
        }

        let model = await loaded(containers, spaces: spaces, seams: seams)
        guard case .failed(let copy) = model.spaceChoice else {
            Issue.record("expected the failure")
            return
        }
        #expect(copy.title == L10n.Errors.Offline.title)
        #expect(copy.body == L10n.Errors.Offline.read)

        await spaces.set(list: .value([PlacesFixtures.spaceRow(PlacesFixtures.space())]))
        model.retrySpaces()
        await placesSettle(model.spaces)
        guard case .options(let rows) = model.spaceChoice else {
            Issue.record("expected the list")
            return
        }
        #expect(rows.map(\.id) == ["garage"])
    }

    @Test("Delete asks with what goes with it; Cancel frees the form")
    func deleteAsks() async throws {
        let seams = PlacesSeams(confirmAnswers: [false])
        let containers = PlacesFakeContainers()
        await containers.set(impact: .value(ContainerDeletionImpact(itemCount: 5, photoCount: 2, hasQrBinding: true)))
        let model = await loaded(containers, seams: seams)

        await model.delete()

        let asked = try #require(seams.confirm.asked.first)
        #expect(asked.title == "Delete Tool chest?")
        #expect(asked.body == "This also deletes 5 items and unlinks its QR label. This cannot be undone.")
        #expect(asked.confirmLabel == "Delete")
        #expect(await containers.deletes.isEmpty)
        #expect(model.busy == nil)
    }

    @Test("Delete confirmed opens the space it was stored in, not the one the form was switched to")
    func deletesAndOpensItsSpace() async {
        let seams = PlacesSeams(confirmAnswers: [true])
        let containers = PlacesFakeContainers()
        await containers.set(
            impact: .value(ContainerDeletionImpact(itemCount: 3, photoCount: 1, hasQrBinding: false)),
            delete: .value(DeletionResult(deleted: true, orphanedPhotoUris: ["file:///p.webp"]))
        )
        let model = await loaded(containers, seams: seams)
        model.setSpace("attic")

        await model.delete()

        #expect(await containers.deletes == ["chest"])
        #expect(seams.photos.deleted == [["file:///p.webp"]])
        #expect(seams.telemetry.events == [RecordingTelemetry.Entry(level: "event", name: "container_deleted", payload: ["itemCount": .int(3)])])
        #expect(seams.invalidations.count == 1)
        #expect(screen.navigations == [.openSpace(id: "garage")])
        #expect(seams.toasts.messages == ["Tool chest was deleted."])
        #expect(seams.haptics.played.isEmpty)
    }

    @Test("an unnamed container's delete names it by its code; already deleted is said, not counted")
    func alreadyDeletedByCode() async throws {
        let seams = PlacesSeams(confirmAnswers: [true])
        let containers = PlacesFakeContainers()
        await containers.set(delete: .value(.notDeleted))
        let model = await loaded(containers, stored: PlacesFixtures.container(name: nil, shortCode: "BOX-7K2M"), seams: seams)

        await model.delete()

        #expect(try #require(seams.confirm.asked.first).title == "Delete BOX-7K2M?")
        #expect(try #require(seams.confirm.asked.first).body == "This container is empty.")
        #expect(seams.telemetry.names.isEmpty)
        #expect(seams.photos.deleted.isEmpty)
        #expect(seams.toasts.messages == ["BOX-7K2M was already deleted, probably on another phone."])
    }

    @Test("a failed delete keeps the container and says so")
    func deleteFails() async {
        let seams = PlacesSeams(confirmAnswers: [true])
        let containers = PlacesFakeContainers()
        await containers.set(delete: .failure(placesOffline))
        let model = await loaded(containers, seams: seams)

        await model.delete()

        #expect(seams.toasts.messages == ["Tool chest was not deleted. Check the connection and try again."])
        #expect(seams.toasts.last?.tone == .error)
        #expect(seams.haptics.played == [.error])
        #expect(model.busy == nil)
        #expect(screen.navigations.isEmpty)
    }
}
