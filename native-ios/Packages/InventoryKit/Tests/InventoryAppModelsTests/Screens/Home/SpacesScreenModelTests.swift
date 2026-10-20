import InventoryCore
import InventoryStorage
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// The Spaces tab's states (06 §6; app/(tabs)/spaces.tsx:84-151).
@Suite("SpacesScreenModel (app/(tabs)/spaces.tsx)")
@MainActor
struct SpacesScreenModelTests {
    private typealias Fixtures = ShellFixtures

    @MainActor
    private final class Pairing {
        var paired = false
    }

    private func model(_ reads: ShellQueuedReads<[SpaceWithCounts]>, pairing: Pairing = Pairing()) -> SpacesScreenModel {
        SpacesScreenModel(read: reads.read, isPaired: { pairing.paired })
    }

    private func appear(_ model: SpacesScreenModel) async {
        model.query.focusChanged(true)
        await model.query.readTask?.value
    }

    @Test("a skeleton until the first read answers; reads the 'spaces' key")
    func loading() {
        let model = model(ShellQueuedReads([.value([])]))
        #expect(model.query.key == "spaces")
        guard case .loading? = model.placeholder else {
            Issue.record("expected the skeleton, got \(String(describing: model.placeholder))")
            return
        }
        #expect(model.subtitle == nil)
        #expect(!model.showsNewSpaceRow)
        #expect(!model.showsRefreshBanner)
    }

    @Test("spaces: the count under the title, the rows and New space at the end")
    func list() async {
        let model = model(ShellQueuedReads([.value([Fixtures.space("Attic", containers: 1, items: 1), Fixtures.space("Garage", containers: 3, items: 5)])]))
        await appear(model)
        #expect(model.placeholder == nil)
        #expect(model.spaces.map(\.id) == ["Attic", "Garage"])
        #expect(model.subtitle == L10n.Spaces.count(spaces: 2))
        #expect(model.subtitle == "2 spaces")
        #expect(model.showsNewSpaceRow)
    }

    @Test("a failed first read is never 'no spaces yet' (issue #12)")
    func failedFirstRead() async {
        let model = model(ShellQueuedReads([.failure(ShellTestError())]))
        await appear(model)
        guard case .failed? = model.placeholder else {
            Issue.record("expected the error state, got \(String(describing: model.placeholder))")
            return
        }
        #expect(model.subtitle == nil)
        #expect(!model.showsRefreshBanner)
    }

    @Test("no spaces yet: start with one, and join instead only when not joined", arguments: [false, true])
    func empty(paired: Bool) async {
        let pairing = Pairing()
        pairing.paired = paired
        let model = model(ShellQueuedReads([.value([])]), pairing: pairing)
        await appear(model)
        guard case .start(let offersJoin)? = model.placeholder else {
            Issue.record("expected the empty state, got \(String(describing: model.placeholder))")
            return
        }
        #expect(offersJoin == !paired)
        // No "0 spaces" over the empty state.
        #expect(model.subtitle == nil)
        #expect(!model.showsNewSpaceRow)
    }

    @Test("a failed refresh keeps the spaces under the banner")
    func refreshFailed() async {
        let reads = ShellQueuedReads<[SpaceWithCounts]>([.value([Fixtures.space("Garage", containers: 1, items: 2)])])
        let model = model(reads)
        await appear(model)

        reads.answer([.failure(ShellTestError())])
        model.retry()
        await model.query.readTask?.value
        #expect(model.showsRefreshBanner)
        #expect(model.spaces.map(\.id) == ["Garage"])
        #expect(model.placeholder == nil)
    }

    @Test("an offline or revoked refresh over the old list shows no banner: the connection banner and the removed-phone layer say it", arguments: [
        HouseholdHttpError(status: 0, code: "offline"),
        HouseholdHttpError(status: 401, code: "unauthorized"),
    ])
    func explainedElsewhere(error: HouseholdHttpError) async {
        let calls = ShellEventLog()
        let model = SpacesScreenModel(
            read: {
                calls.record("read")
                if calls.events.count > 1 { throw error }
                return [ShellFixtures.space("Garage", containers: 1, items: 2)]
            },
            isPaired: { true })
        await appear(model)
        model.retry()
        await model.query.readTask?.value
        #expect(model.query.refreshFailed)
        #expect(!model.showsRefreshBanner)
        #expect(model.spaces.count == 1)
    }

    @Test("pull to refresh returns once the read has answered")
    func pull() async {
        let reads = ShellHeldReads<[SpaceWithCounts]>()
        let model = SpacesScreenModel(read: reads.read, isPaired: { false })
        let pulling = Task { await model.refresh() }
        await reads.waitForCalls(1)
        #expect(model.query.isLoading)
        reads.succeed([])
        await pulling.value
        #expect(!model.query.isLoading)
    }

    @Test("reads through real repositories")
    func repositories() async throws {
        let store = try DatabaseStore.inMemory()
        try await store.migrate()
        let repositories = LocalRepositories(store: store)
        _ = try await repositories.spaces.create(CreateSpaceInput(name: "Loft", icon: "📦", color: "#81B29A"))
        let model = SpacesScreenModel(repositories: repositories, isPaired: { false })
        await appear(model)
        #expect(model.spaces.map(\.name) == ["Loft"])
    }
}
