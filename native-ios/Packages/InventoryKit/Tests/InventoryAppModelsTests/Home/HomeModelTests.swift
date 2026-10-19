import InventoryCore
import InventoryStorage
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// Home's model end to end over fake reads (06 §5.1-5.10; app/(tabs)/index.tsx).
@Suite("HomeModel (app/(tabs)/index.tsx)")
@MainActor
struct HomeModelTests {
    private typealias Fixtures = ShellFixtures

    /// The household and connection as the test sets them.
    @MainActor
    private final class Context {
        var householdName: String?
        var online = false
        var offline = false

        var value: HomeContext {
            HomeContext(
                householdName: { [self] in householdName },
                connectionIsOnline: { [self] in online },
                connectionIsOffline: { [self] in offline })
        }
    }

    @MainActor
    private final class Harness {
        let clock = ManualClock()
        let context = Context()
        let preferences = InMemoryPreferences()
        let spaces = ShellQueuedReads<[SpaceWithCounts]>([.value([Fixtures.space("Garage", containers: 4, items: 21)])])
        let recent = ShellQueuedReads<[ItemWithContext]>([.value([Fixtures.item("a", category: "Tools")])])
        let containers = ShellQueuedReads<[ContainerWithSpace]>([.value([Fixtures.container("box")])])
        let searches = ShellQueuedReads<SearchResults>([.value(Fixtures.results([Fixtures.hit("a")]))])
        let dropZoneReads = ShellQueuedReads<[ItemWithContext]>([.value([])])
        let categories = ShellEventLog()
        let dropZone: DropZoneModel
        let model: HomeModel

        init() {
            let spaces = spaces, recent = recent, containers = containers, searches = searches
            let categories = categories
            dropZone = DropZoneModel(read: dropZoneReads.read)
            model = HomeModel(
                reads: HomeReads(
                    spaces: { try spaces.call("") },
                    recent: { try recent.call("\($0)") },
                    containers: { try containers.call("") },
                    search: { try searches.call($0) }),
                dropZone: dropZone,
                context: context.value,
                unpairedNotice: UnpairedNoticeModel(preference: UnpairedNoticePreference(preferences: preferences)),
                clock: clock,
                telemetry: TelemetryReporter(sink: RecordingTelemetry()),
                rememberCategories: { categories.record($0.map { $0 ?? "nil" }.joined(separator: ",")) })
        }

        /// Home appears focused and every read answers.
        func appear() async {
            model.focusChanged(true)
            dropZone.focusChanged(true)
            await settleReads()
        }

        func settleReads() async {
            await model.spaces.readTask?.value
            await model.recent.readTask?.value
            await model.containers.readTask?.value
            await dropZone.query.readTask?.value
            await model.search.searchTask?.value
        }
    }

    @Test("the overview: the field, the notice, then Recently added; categories remembered")
    func overview() async {
        let harness = Harness()
        await harness.appear()
        #expect(harness.model.entries.map(\.kind) == [.field, .notice, .title, .item])
        #expect(harness.model.summaryLine == "1 space, 4 containers and 21 items.")
        #expect(harness.model.whereLine == L10n.Connection.local)
        #expect(harness.model.title == L10n.Home.title)
        #expect(!harness.model.paired)
        #expect(harness.categories.events == ["Tools"])
        #expect(harness.recent.arguments == ["12"])
        #expect(harness.containers.callCount == 0)
        #expect(harness.model.containers.key == "containers-none")
    }

    @Test("the notice stays hidden until the preference is read, and Not now puts it away for good")
    func notice() async {
        let harness = Harness()
        #expect(!harness.model.noticeVisible)
        await harness.appear()
        #expect(harness.model.noticeVisible)
        harness.model.dismissNotice()
        #expect(!harness.model.noticeVisible)
        #expect(harness.preferences.values[PreferenceKey.unpairedNoticeDismissed] == "1")

        let dismissed = Harness()
        dismissed.preferences.setString("1", forKey: PreferenceKey.unpairedNoticeDismissed)
        await dismissed.appear()
        #expect(!dismissed.model.noticeVisible)
    }

    @Test("a joined phone shows its household's name, no notice, and the shared caption")
    func paired() async {
        let harness = Harness()
        harness.context.householdName = "  The Smiths "
        harness.context.online = true
        await harness.appear()
        #expect(harness.model.title == "The Smiths")
        #expect(!harness.model.noticeVisible)
        #expect(harness.model.whereLine == L10n.Connection.shared)
        harness.context.online = false
        harness.context.offline = true
        #expect(harness.model.reconnecting)
        #expect(harness.model.whereLine == L10n.Connection.sharedReconnecting)
        harness.context.householdName = "   "
        #expect(harness.model.title == L10n.Home.title)
    }

    @Test("the empty unpaired household starts here, without the notice repeating the offer")
    func startHere() async {
        let harness = Harness()
        harness.spaces.answer([.value([])])
        harness.recent.answer([.value([])])
        await harness.appear()
        #expect(harness.model.startHere)
        #expect(harness.model.entries.map(\.kind) == [.field, .status])
        #expect(harness.model.summaryLine == nil)
        #expect(harness.model.idleBody == .status(.empty))
    }

    @Test("Show more asks for forty; a failure keeps the twelve under the stale-data banner")
    func showMoreKeepsRows() async {
        let harness = Harness()
        let twelve = (1...12).map { Fixtures.item("\($0)") }
        harness.recent.answer([.value(twelve), .failure(ShellTestError())])
        await harness.appear()
        #expect(harness.model.entries.last?.kind == .more)
        harness.model.showMore()
        #expect(harness.model.recentLimit == 40)
        #expect(harness.model.recentRows?.count == 12)
        await harness.model.recent.readTask?.value
        #expect(harness.recent.arguments == ["12", "40"])
        #expect(harness.model.recent.data == nil)
        #expect(harness.model.recentRows?.count == 12)
        let kinds = harness.model.entries.map(\.kind)
        #expect(kinds.prefix(2) == [.field, .refreshFailed])
        #expect(!kinds.contains(.more))
    }

    @Test("an overview failure the connection explains says 'waiting'; otherwise the error state")
    func overviewError() async {
        let harness = Harness()
        harness.context.householdName = "Home"
        harness.recent.answer([.failure(ShellTestError())])
        await harness.appear()
        #expect(harness.model.idleBody == .status(.error))
        #expect(harness.model.overviewCause != nil)
        #expect(!harness.model.overviewWaitingForServer)
    }

    @Test("containers are read once she heads for the field, and from then on")
    func wantsPlaces() async {
        let harness = Harness()
        await harness.appear()
        harness.model.setFieldFocused(true)
        #expect(harness.model.isCompact)
        #expect(harness.model.wantsPlaces)
        await harness.model.containers.readTask?.value
        #expect(harness.model.containers.key == "containers-all")
        #expect(harness.model.containersById["box"] != nil)
        harness.model.setFieldFocused(false)
        #expect(harness.model.wantsPlaces)
        #expect(!harness.model.isCompact)
    }

    @Test("typing: results replace the overview, the list jumps to the top, the chip closes")
    func search() async throws {
        let harness = Harness()
        await harness.appear()
        harness.model.toggleExpand("a")
        #expect(harness.model.expandedId == "a")
        harness.model.setQuery("item")
        #expect(harness.model.scrollToTopRequests == 1)
        #expect(harness.model.expandedId == nil)
        #expect(harness.model.wantsPlaces)
        #expect(harness.model.entries == [.field, .status(.searching)])

        // The debounce and the search skeleton's wait.
        try await harness.clock.waitForSleepers(2)
        await harness.clock.advance(by: .milliseconds(200))
        await harness.settleReads()
        #expect(harness.model.entries.map(\.kind) == [.field, .title, .item])
        #expect(harness.model.highlightTerms == ["x"])

        harness.model.setQuery("items")
        #expect(harness.model.scrollToTopRequests == 1)
        harness.model.toggleExpand("a")
        harness.model.toggleExpand("a")
        #expect(harness.model.expandedId == nil)

        // Writing the same text again (a binding echo) is not typing: the open chip stays.
        harness.model.toggleExpand("a")
        harness.model.setQuery("items")
        #expect(harness.model.expandedId == "a")
        harness.model.setQuery("items ")
        #expect(harness.model.expandedId == nil)
    }

    @Test("older results stay dimmed, then the skeleton mounts at 420 ms and takes over at 600 ms")
    func olderResultsHandover() async throws {
        let harness = Harness()
        await harness.appear()
        harness.model.setQuery("item")
        // The debounce and the search skeleton's wait.
        try await harness.clock.waitForSleepers(2)
        await harness.clock.advance(by: .milliseconds(200))
        await harness.settleReads()

        harness.searches.answer([.value(Fixtures.results([Fixtures.hit("b")]))])
        let start = harness.clock.now.offset
        harness.model.setQuery("items")
        #expect(harness.model.dim)
        #expect(harness.model.entries.map(\.kind) == [.field, .title, .item])
        // The debounce, and the two handover waits.
        try await harness.clock.waitForSleepers(3)
        await harness.clock.advance(to: ManualClock.Instant(offset: start + .milliseconds(200)))
        // The debounce has passed: the new search is answered at once by the fake.
        await harness.settleReads()
        #expect(!harness.model.dim)
        #expect(harness.model.search.results?.items.first?.id == "b")
    }

    @Test("with a slow search the older results give way on time")
    func slowSearchHandover() async throws {
        let clock = ManualClock()
        let held = ShellHeldReads<SearchResults>()
        let dropZone = DropZoneModel(read: ShellQueuedReads<[ItemWithContext]>([.value([])]).read)
        let model = HomeModel(
            reads: HomeReads(
                spaces: { [] }, recent: { _ in [] }, containers: { [] },
                search: { try await held.call($0) }),
            dropZone: dropZone, context: .local, unpairedNotice: UnpairedNoticeModel(preference: UnpairedNoticePreference(preferences: InMemoryPreferences())), clock: clock,
            telemetry: TelemetryReporter(sink: RecordingTelemetry()))
        model.focusChanged(true)
        model.setQuery("glue")
        try await clock.waitForSleepers(2)
        await clock.advance(by: .milliseconds(200))
        await held.waitForCalls(1)
        held.succeed(ShellFixtures.results([ShellFixtures.hit("g")]))
        await model.search.searchTask?.value

        model.setQuery("tape")
        let start = clock.now.offset
        #expect(model.dim)
        #expect(!model.searchSkeletonVisible)
        try await clock.waitForSleepers(3)
        await clock.advance(to: ManualClock.Instant(offset: start + .milliseconds(419)))
        #expect(model.entries.first(where: { $0.kind == .status }) == nil)
        await clock.advance(to: ManualClock.Instant(offset: start + .milliseconds(420)))
        #expect(model.mountSkeleton.value)
        #expect(model.entries.prefix(2) == [.field, .status(.searching)])
        #expect(model.dim)
        await clock.advance(to: ManualClock.Instant(offset: start + .milliseconds(600)))
        #expect(!model.dim)
        #expect(model.entries == [.field, .status(.searching)])
        #expect(model.searchSkeletonVisible)
        await held.waitForCalls(2)
        held.succeed(ShellFixtures.results([ShellFixtures.hit("t")]))
        await model.search.searchTask?.value
        #expect(!model.mountSkeleton.value)
        #expect(model.entries.map(\.kind) == [.field, .title, .item])
    }

    @Test("Try again on the banner retries the search while searching, else the overview")
    func retry() async throws {
        let harness = Harness()
        await harness.appear()
        harness.model.retry()
        await harness.settleReads()
        #expect(harness.spaces.callCount == 2)
        #expect(harness.recent.callCount == 2)
        #expect(harness.dropZoneReads.callCount == 2)

        harness.model.setQuery("item")
        // The debounce and the search skeleton's wait.
        try await harness.clock.waitForSleepers(2)
        await harness.clock.advance(by: .milliseconds(200))
        await harness.settleReads()
        harness.model.retry()
        await harness.settleReads()
        #expect(harness.searches.callCount == 2)
        #expect(harness.spaces.callCount == 2)
    }

    @Test("pull to refresh returns once every read it asked for has answered")
    func refresh() async throws {
        let harness = Harness()
        await harness.appear()
        harness.model.setQuery("item")
        // The debounce and the search skeleton's wait.
        try await harness.clock.waitForSleepers(2)
        await harness.clock.advance(by: .milliseconds(200))
        await harness.settleReads()
        await harness.model.refresh()
        #expect(!harness.model.refreshing)
        #expect(harness.spaces.callCount == 2)
        #expect(harness.searches.callCount == 2)
        #expect(harness.containers.callCount == 2)
    }

    @Test("the search error says offline when the home server did not answer, else 'did not finish'")
    func searchFailedCopy() async throws {
        let harness = Harness()
        harness.searches.answer([.failure(ShellTestError())])
        await harness.appear()
        harness.model.setQuery("item")
        // The debounce and the search skeleton's wait.
        try await harness.clock.waitForSleepers(2)
        await harness.clock.advance(by: .milliseconds(200))
        await harness.settleReads()
        #expect(harness.model.entries == [.field, .status(.searchFailed)])
        #expect(harness.model.searchFailedCopy?.title == L10n.Search.failed)
        #expect(harness.model.searchFailedCopy?.body == L10n.Errors.Local.read)
    }

    @Test("new reads are used from the next read on, and nothing is read until the caller invalidates")
    func setReads() async {
        let harness = Harness()
        await harness.appear()
        let household = ShellQueuedReads<[SpaceWithCounts]>([.value([])])
        harness.model.setReads(HomeReads(
            spaces: { try household.call("") }, recent: { _ in [] }, containers: { [] },
            search: { _ in .empty }))
        await ShellWait.settle()
        #expect(household.callCount == 0)
        harness.model.revisionChanged(1)
        await harness.settleReads()
        #expect(household.callCount == 1)
        #expect(harness.model.spaces.data == [])
    }

    @Test("reads through real repositories")
    func repositories() async throws {
        let store = try DatabaseStore.inMemory()
        try await store.migrate()
        let repositories = LocalRepositories(store: store)
        let space = try await repositories.spaces.create(CreateSpaceInput(name: "Garage", icon: "🧰", color: "#5B8DEF"))
        let box = try await repositories.containers.create(CreateContainerInput(spaceId: space.id, name: "Tool chest", visualType: .box))
        _ = try await repositories.items.create(ItemDraft(containerId: box.id, name: "Drill"))
        let model = HomeModel(
            reads: HomeReads(repositories: repositories),
            dropZone: DropZoneModel(repositories: repositories),
            context: .local, unpairedNotice: UnpairedNoticeModel(preference: UnpairedNoticePreference(preferences: InMemoryPreferences())),
            telemetry: TelemetryReporter(sink: RecordingTelemetry()))
        model.focusChanged(true)
        model.dropZone.focusChanged(true)
        await model.spaces.readTask?.value
        await model.recent.readTask?.value
        await model.dropZone.query.readTask?.value
        #expect(model.summaryLine == "1 space, 1 container and 1 item.")
        #expect(model.recentRows?.map(\.item.name) == ["Drill"])
    }
}
