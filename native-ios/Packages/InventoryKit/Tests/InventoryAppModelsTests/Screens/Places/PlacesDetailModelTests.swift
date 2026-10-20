import Foundation
import InventoryCore
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

// The space and container screens (app/space/[id]/index.tsx, app/container/[id]/index.tsx;
// 07 §3.7, §3.12): what shows while reads are out, sorting, the head, and the rows' upkeep.

@Suite("Space detail (space/[id]/index.tsx)")
@MainActor
struct PlacesSpaceDetailModelTests {
    private func makeModel(_ spaces: PlacesFakeSpaces, _ containers: PlacesFakeContainers) -> SpaceDetailModel {
        SpaceDetailModel(id: "garage", spaces: spaces, containers: containers)
    }

    private func loaded(_ spaces: PlacesFakeSpaces, _ containers: PlacesFakeContainers) async -> SpaceDetailModel {
        let model = makeModel(spaces, containers)
        model.focusChanged(true, revision: 0)
        await placesSettle(model.space, model.containers)
        return model
    }

    @Test("sorts the containers by label, codes alongside names, keeping repository order on ties, and totals the items")
    func sortsAndTotals() async throws {
        let spaces = PlacesFakeSpaces()
        await spaces.set(byId: .value(PlacesFixtures.space()))
        let containers = PlacesFakeContainers()
        // Newest first, as the repository returns them.
        await containers.set(bySpace: .value([
            PlacesFixtures.containerRow(PlacesFixtures.container(id: "d", name: "drawer by the oven"), items: 4),
            PlacesFixtures.containerRow(PlacesFixtures.container(id: "b", name: nil, shortCode: "BOX-4F2A"), items: 0),
            PlacesFixtures.containerRow(PlacesFixtures.container(id: "e1", name: "Étagère"), items: 1),
            PlacesFixtures.containerRow(PlacesFixtures.container(id: "a", name: "Attic box"), items: 2),
            PlacesFixtures.containerRow(PlacesFixtures.container(id: "e2", name: "etagere"), items: 0),
        ]))
        let model = await loaded(spaces, containers)

        #expect(model.blocking == nil)
        #expect(model.sorted.map(\.id) == ["a", "b", "d", "e1", "e2"])
        #expect(model.itemTotal == 7)
        #expect(model.meta == "5 containers and 7 items")
        #expect(model.hasBottomBar)
        #expect(model.editLabel == "Edit Garage")
        guard case .rows(let rows) = model.contents else {
            Issue.record("expected rows")
            return
        }
        #expect(rows.count == 5)
    }

    @Test("an empty space says so with no counts; a failed containers read is never 'no containers yet'")
    func emptyAndFailed() async {
        let spaces = PlacesFakeSpaces()
        await spaces.set(byId: .value(PlacesFixtures.space(name: "Shed")))
        let containers = PlacesFakeContainers()
        let model = await loaded(spaces, containers)
        guard case .empty = model.contents else {
            Issue.record("expected the empty state")
            return
        }
        #expect(model.meta == nil)
        #expect(!model.hasBottomBar)
        #expect(model.emptyTitle == "No containers in Shed yet")

        await containers.set(bySpace: .failure(PlacesFailure()))
        let failing = await loaded(spaces, containers)
        guard case .failed = failing.contents else {
            Issue.record("expected the failure, not the empty state")
            return
        }
    }

    @Test("before the space: loading, a failed read, or gone; never gone while it loads")
    func blocking() async {
        let spaces = PlacesFakeSpaces()
        let containers = PlacesFakeContainers()
        let model = makeModel(spaces, containers)
        guard case .loading? = model.blocking else {
            Issue.record("expected loading")
            return
        }
        guard case .loading = model.contents else {
            Issue.record("expected the rows' skeleton")
            return
        }
        model.focusChanged(true, revision: 0)
        await placesSettle(model.space, model.containers)
        guard case .gone? = model.blocking else {
            Issue.record("expected gone")
            return
        }
        await spaces.set(byId: .failure(PlacesFailure()))
        model.reloadAll()
        guard case .loading? = model.blocking else {
            Issue.record("expected loading again")
            return
        }
        await placesSettle(model.space, model.containers)
        guard case .failed? = model.blocking else {
            Issue.record("expected the failure")
            return
        }
    }

    @Test("the refresh banner shows for a failed refresh, but not when offline explains it")
    func refreshBanner() async {
        let spaces = PlacesFakeSpaces()
        await spaces.set(byId: .value(PlacesFixtures.space()))
        let containers = PlacesFakeContainers()
        await containers.set(bySpace: .value([PlacesFixtures.containerRow(PlacesFixtures.container())]))
        let model = await loaded(spaces, containers)
        #expect(!model.showsRefreshBanner)

        await containers.set(bySpace: .failure(PlacesFailure()))
        await model.refresh()
        #expect(model.showsRefreshBanner)
        #expect(model.sorted.count == 1)

        await containers.set(bySpace: .failure(placesOffline))
        await model.refresh()
        #expect(!model.showsRefreshBanner)
    }
}

@Suite("Container detail (container/[id]/index.tsx)")
@MainActor
struct PlacesContainerDetailModelTests {
    private let quantities = ItemRowQuantityModels { item in
        SavedQuantityModel(
            itemId: item.id,
            quantity: item.quantity,
            updatedAt: item.updatedAt,
            items: PlacesFakeItems(),
            invalidator: SharedSeamsInvalidationCounter(),
            haptics: { _ in }
        )
    }

    private func makeModel(
        _ containers: PlacesFakeContainers,
        _ items: PlacesFakeItems,
        spaces: PlacesFakeSpaces = PlacesFakeSpaces(),
        remembered: PlacesCategoryLog = PlacesCategoryLog(),
        now: Int64 = 1_000_000
    ) -> ContainerDetailModel {
        ContainerDetailModel(
            id: "chest",
            spaces: spaces,
            containers: containers,
            items: items,
            quantities: quantities,
            rememberCategories: { remembered.calls.append($0) },
            now: { now }
        )
    }

    private func settle(_ model: ContainerDetailModel) async {
        await placesSettle(model.container, model.items)
        await placesSettle(model.space)
    }

    @Test("nothing shows until both the container and its contents are read, so it never flashes empty")
    func waitsForBothReads() async {
        let containers = PlacesFakeContainers()
        await containers.set(withCounts: .value(PlacesFixtures.containerRow(PlacesFixtures.container())))
        let items = PlacesFakeItems()
        let gate = PlacesGate()
        await items.set(gate: gate)
        let model = makeModel(containers, items)
        guard case .loading? = model.blocking else {
            Issue.record("expected loading")
            return
        }
        model.focusChanged(true, revision: 0)
        await placesSettle(model.container)
        // The container is in, its items not yet: still loading, never "empty".
        #expect(model.containerData != nil)
        guard case .loading? = model.blocking else {
            Issue.record("expected loading while the items are out")
            return
        }
        await gate.open()
        await settle(model)
        #expect(model.blocking == nil)
        guard case .empty = model.contents else {
            Issue.record("expected the empty state")
            return
        }
    }

    @Test("a container found gone, a failed container read, and a failed items read said as such")
    func failures() async {
        let containers = PlacesFakeContainers()
        let items = PlacesFakeItems()
        let gone = makeModel(containers, items)
        gone.focusChanged(true, revision: 0)
        await settle(gone)
        guard case .gone? = gone.blocking else {
            Issue.record("expected gone")
            return
        }

        await containers.set(withCounts: .failure(PlacesFailure()))
        let failed = makeModel(containers, items)
        failed.focusChanged(true, revision: 0)
        await settle(failed)
        guard case .failed? = failed.blocking else {
            Issue.record("expected the failed read")
            return
        }

        await containers.set(withCounts: .value(PlacesFixtures.containerRow(PlacesFixtures.container())))
        await items.set(contents: .failure(PlacesFailure()))
        let noItems = makeModel(containers, items)
        noItems.focusChanged(true, revision: 0)
        await settle(noItems)
        #expect(noItems.blocking == nil)
        guard case .failed = noItems.contents else {
            Issue.record("expected the items' failure, not an empty box")
            return
        }
    }

    @Test("the space read follows the container's space, and the crumb comes from it")
    func spaceFollowsTheContainer() async throws {
        let containers = PlacesFakeContainers()
        await containers.set(withCounts: .value(PlacesFixtures.containerRow(PlacesFixtures.container(spaceId: "garage"))))
        let spaces = PlacesFakeSpaces()
        await spaces.set(byId: .value(PlacesFixtures.space(id: "garage", name: "Garage", color: "#5B8DEF")))
        let model = makeModel(containers, PlacesFakeItems(), spaces: spaces)
        #expect(model.space.key == "space:none")

        model.focusChanged(true, revision: 0)
        await settle(model)

        #expect(model.space.key == "space:garage")
        #expect(await spaces.reads == ["garage"])
        #expect(model.crumb == ContainerDetailModel.Crumb(id: "garage", name: "Garage", color: "#5B8DEF"))
        #expect(!model.keepsCrumbRoom)
    }

    @Test("without the space read, the crumb comes from the first row; room is kept unless the read failed")
    func crumbFallbacks() async {
        let containers = PlacesFakeContainers()
        await containers.set(withCounts: .value(PlacesFixtures.containerRow(PlacesFixtures.container())))
        let spaces = PlacesFakeSpaces()
        await spaces.set(byId: .failure(PlacesFailure()))
        let items = PlacesFakeItems()
        await items.set(contents: .value([
            PlacesFixtures.item(id: "z", name: "Zip ties", spaceId: "garage", spaceName: "Garage", spaceColor: "#5B8DEF"),
            PlacesFixtures.item(id: "a", name: "Allen keys", spaceId: "garage", spaceName: "Garage", spaceColor: "#5B8DEF"),
        ]))
        let model = makeModel(containers, items, spaces: spaces)
        model.focusChanged(true, revision: 0)
        await settle(model)
        #expect(model.crumb == ContainerDetailModel.Crumb(id: "garage", name: "Garage", color: "#5B8DEF"))

        await items.set(contents: .value([]))
        let empty = makeModel(containers, items, spaces: spaces)
        empty.focusChanged(true, revision: 0)
        await settle(empty)
        #expect(empty.crumb == nil)
        #expect(!empty.keepsCrumbRoom)
    }

    @Test("the head: title by type when unnamed, the type alone when empty, the count otherwise, and the QR entry")
    func head() async {
        let containers = PlacesFakeContainers()
        await containers.set(withCounts: .value(PlacesFixtures.containerRow(
            PlacesFixtures.container(name: nil, visualType: .bin, shortCode: "BIN-4F2A"), items: 9, qrToken: nil)))
        let items = PlacesFakeItems()
        let empty = makeModel(containers, items)
        empty.focusChanged(true, revision: 0)
        await settle(empty)
        #expect(empty.title == "Unnamed bin")
        #expect(empty.subline == "Bin")
        #expect(empty.emptyTitle == "This bin is empty")
        #expect(empty.qrLabel == "Add a QR label")
        #expect(empty.qrAccessibilityLabel == "Add a QR label")
        #expect(empty.codeAccessibilityLabel == "Label code B I N, 4 F 2 A")
        #expect(empty.editLabel == "Edit Unnamed bin")
        #expect(!empty.hasBottomBar)

        await containers.set(withCounts: .value(PlacesFixtures.containerRow(PlacesFixtures.container(), items: 1, qrToken: "t")))
        await items.set(contents: .value([PlacesFixtures.item(id: "a", name: "Drill"), PlacesFixtures.item(id: "b", name: "Saw")]))
        let full = makeModel(containers, items)
        full.focusChanged(true, revision: 0)
        await settle(full)
        #expect(full.title == "Tool chest")
        #expect(full.subline == "Cabinet · 2 items")
        #expect(full.qrLabel == "QR label")
        #expect(full.qrAccessibilityLabel == "QR label, linked. Opens the label.")
        #expect(full.hasBottomBar)
    }

    @Test("rows sort by name; each read feeds the categories and keeps quantity models only for the rows shown")
    func rowsUpkeep() async {
        let containers = PlacesFakeContainers()
        await containers.set(withCounts: .value(PlacesFixtures.containerRow(PlacesFixtures.container())))
        let items = PlacesFakeItems()
        let drill = PlacesFixtures.item(id: "d", name: "drill", category: "Tools", createdAt: 3)
        let unnamed = PlacesFixtures.item(id: "u", name: "", createdAt: 1)
        let allen = PlacesFixtures.item(id: "a", name: "Allen keys", category: nil, createdAt: 2)
        await items.set(contents: .value([drill, unnamed, allen]))
        let remembered = PlacesCategoryLog()
        let model = makeModel(containers, items, remembered: remembered)
        model.focusChanged(true, revision: 0)
        await settle(model)

        #expect(model.sorted.map(\.id) == ["a", "d", "u"])
        #expect(remembered.calls == [["Tools", nil, nil]])
        _ = quantities.model(for: drill)
        _ = quantities.model(for: unnamed)
        #expect(quantities.count == 2)

        await items.set(contents: .value([drill]))
        model.revisionChanged(1)
        await settle(model)
        #expect(quantities.count == 1)
        #expect(remembered.calls.count == 2)
    }

    @Test("a just-added row is picked out once, decided when it first appears")
    func arrival() async {
        let containers = PlacesFakeContainers()
        let model = makeModel(containers, PlacesFakeItems(), now: 50_000)
        let fresh = PlacesFixtures.item(id: "f", name: "New", createdAt: 45_000)
        let old = PlacesFixtures.item(id: "o", name: "Old", createdAt: 40_000)

        #expect(model.claimsArrival(fresh))
        #expect(!model.claimsArrival(fresh))
        #expect(!model.claimsArrival(old))
    }

    @Test("the highlight holds 600 ms then fades over 1200 ms; under Reduce Motion it holds 1800 ms and goes at once")
    func arrivalTiming() {
        #expect(ContainerDetailModel.arrivalTiming(reduceMotion: false) == .init(holdMs: 600, fadeMs: 1200))
        #expect(ContainerDetailModel.arrivalTiming(reduceMotion: true) == .init(holdMs: 1800, fadeMs: 0))
    }

    @Test("pull to refresh re-reads all three and waits for them")
    func refreshReadsAll() async {
        let containers = PlacesFakeContainers()
        await containers.set(withCounts: .value(PlacesFixtures.containerRow(PlacesFixtures.container())))
        let spaces = PlacesFakeSpaces()
        await spaces.set(byId: .value(PlacesFixtures.space()))
        let model = makeModel(containers, PlacesFakeItems(), spaces: spaces)
        model.focusChanged(true, revision: 0)
        await settle(model)
        let readsBefore = await spaces.reads.count

        await model.refresh()

        #expect(!model.container.isLoading && !model.items.isLoading && !model.space.isLoading)
        #expect(await spaces.reads.count == readsBefore + 1)
    }
}

/// The categories a container screen fed to the memory, read by read.
@MainActor
final class PlacesCategoryLog {
    var calls: [[String?]] = []
}
