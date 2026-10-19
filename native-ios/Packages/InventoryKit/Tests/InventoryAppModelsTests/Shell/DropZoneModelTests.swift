import InventoryCore
import InventoryStorage
import Testing
@testable import InventoryAppModels

/// 09 §4.8 and 06 §7.1: the shared drop-zone read and its derived values.
@Suite("DropZoneModel (src/providers/DropZoneProvider.tsx)")
@MainActor
struct DropZoneModelTests {
    private let waiting = [ShellFixtures.item("a", containerId: DropZone.containerId), ShellFixtures.item("b", containerId: DropZone.containerId)]

    @Test("empty, counting 0 and loading until the first read answers; badges stay hidden meanwhile")
    func beforeFirstRead() async {
        let reads = ShellHeldReads<[ItemWithContext]>()
        let model = DropZoneModel(read: reads.read)
        #expect(model.items.isEmpty)
        #expect(model.count == 0)
        #expect(model.loading)
        #expect(model.reading)
        #expect(model.query.key == "drop-zone")

        model.focusChanged(true)
        await reads.waitForCalls(1)
        reads.succeed(waiting)
        await model.query.readTask?.value
        #expect(model.items.map(\.id) == ["a", "b"])
        #expect(model.count == 2)
        #expect(!model.loading)
        #expect(!model.reading)
        #expect(model.cause == nil)
    }

    @Test("a refresh in flight is reading but not loading once there is data")
    func readingVersusLoading() async {
        let reads = ShellHeldReads<[ItemWithContext]>()
        let model = DropZoneModel(read: reads.read)
        model.reload()
        await reads.waitForCalls(1)
        reads.succeed(waiting)
        await model.query.readTask?.value
        model.reload()
        await reads.waitForCalls(2)
        #expect(model.reading)
        #expect(!model.loading)
        #expect(model.count == 2)
        reads.succeed([])
        await model.query.readTask?.value
        #expect(model.count == 0)
    }

    @Test("a failed refresh keeps the items under the banner; a failed first read has none")
    func failures() async {
        let reads = ShellQueuedReads<[ItemWithContext]>([.failure(ShellTestError())])
        let first = DropZoneModel(read: reads.read)
        first.reload()
        await first.query.readTask?.value
        #expect(first.cause != nil)
        #expect(!first.refreshFailed)
        #expect(!first.loading)
        #expect(first.count == 0)

        let again = ShellQueuedReads<[ItemWithContext]>([.value(waiting), .failure(ShellTestError())])
        let model = DropZoneModel(read: again.read)
        model.reload()
        await model.query.readTask?.value
        await model.refresh()
        #expect(model.refreshFailed)
        #expect(model.cause != nil)
        #expect(model.count == 2)
    }

    @Test("writes refresh it while the tab shell is in front, and on return otherwise")
    func followsRevisionAndFocus() async {
        let reads = ShellQueuedReads(waiting)
        let model = DropZoneModel(revision: 4, read: reads.read)
        model.focusChanged(true)
        await model.query.readTask?.value
        model.revisionChanged(5)
        await model.query.readTask?.value
        #expect(reads.callCount == 2)
        model.focusChanged(false)
        model.revisionChanged(6)
        await ShellWait.settle()
        #expect(reads.callCount == 2)
        model.focusChanged(true, revision: 6)
        await model.query.readTask?.value
        #expect(reads.callCount == 3)
    }

    @Test("reads through the repositories' listUnsorted, and a new read waits for an invalidate")
    func repositories() async throws {
        let store = try DatabaseStore.inMemory()
        try await store.migrate()
        let repositories = LocalRepositories(store: store)
        _ = try await repositories.items.create(ItemDraft(containerId: DropZone.containerId, name: "Drill"))
        let model = DropZoneModel(repositories: repositories)
        model.reload()
        await model.query.readTask?.value
        #expect(model.items.map(\.item.name) == ["Drill"])

        let household = ShellQueuedReads<[ItemWithContext]>([.value([])])
        model.setRead(household.read)
        await ShellWait.settle()
        #expect(household.callCount == 0)
    }
}
