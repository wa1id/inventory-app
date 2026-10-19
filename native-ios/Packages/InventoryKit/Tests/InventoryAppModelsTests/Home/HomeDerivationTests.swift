import InventoryCore
import Testing
@testable import InventoryAppModels

/// 06 §21: Home's `idleBody` / `searchBody` derivations and `explainedElsewhere`
/// (app/(tabs)/index.tsx; no RN tests exist for the screen).
@Suite("Home derivations (app/(tabs)/index.tsx)")
struct HomeDerivationTests {
    private typealias Fixtures = ShellFixtures

    private static let offline = HouseholdHttpError(status: 0, code: "offline")
    private static let cloudflareDown = HouseholdHttpError(status: 530, code: "http_530")
    private static let revoked = HouseholdHttpError(status: 401, code: "unauthorized")
    private static let server = HouseholdHttpError(status: 500, code: "http_500")
    private static let local = ShellTestError("SQLITE_BUSY")

    // MARK: explainedElsewhere

    @Test("a removed phone is always explained by its layer")
    func revokedExplained() {
        #expect(HomeDerivation.explainedElsewhere(Self.revoked, connectionIsOnline: true))
        #expect(HomeDerivation.explainedElsewhere(Self.revoked, connectionIsOnline: false))
    }

    @Test("an unreachable home server is explained only while the connection says so")
    func offlineExplainedUnlessOnline() {
        #expect(HomeDerivation.explainedElsewhere(Self.offline, connectionIsOnline: false))
        #expect(HomeDerivation.explainedElsewhere(Self.cloudflareDown, connectionIsOnline: false))
        #expect(!HomeDerivation.explainedElsewhere(Self.offline, connectionIsOnline: true))
    }

    @Test("anything else the screen explains itself")
    func otherFailures() {
        #expect(!HomeDerivation.explainedElsewhere(Self.server, connectionIsOnline: false))
        #expect(!HomeDerivation.explainedElsewhere(Self.local, connectionIsOnline: false))
        #expect(!HomeDerivation.explainedElsewhere(ConflictError(updatedAt: 1), connectionIsOnline: false))
    }

    // MARK: idleBody

    private func idle(
        rows: [ItemWithContext]?,
        recentFailed: Bool = false,
        dropZone: Int = 0,
        paired: Bool = false,
        spacesLoaded: Bool = true,
        spacesFailed: Bool = false,
        limit: Int = 12
    ) -> HomeList.IdleBody {
        HomeDerivation.idleBody(
            recentRows: rows, recentFailed: recentFailed, dropZoneCount: dropZone, paired: paired,
            spacesLoaded: spacesLoaded, spacesFailed: spacesFailed, recentLimit: limit)
    }

    @Test("no recent rows yet: loading, or the error when the read failed")
    func noRowsYet() {
        #expect(idle(rows: nil) == .status(.loading))
        #expect(idle(rows: nil, recentFailed: true) == .status(.error))
    }

    @Test("nothing stored and nothing waiting: empty, but unpaired it waits for the spaces first")
    func emptyHousehold() {
        #expect(idle(rows: []) == .status(.empty))
        #expect(idle(rows: [], paired: true, spacesLoaded: false) == .status(.empty))
        #expect(idle(rows: [], spacesLoaded: false) == .status(.loading))
        #expect(idle(rows: [], spacesLoaded: false, spacesFailed: true) == .status(.error))
    }

    @Test("items waiting in the drop zone make it a list, even with no recent rows")
    func dropZoneMakesAList() {
        #expect(idle(rows: [], dropZone: 2) == .list(recent: [], canShowMore: false))
    }

    @Test("Show more is offered only for a full first page")
    func canShowMore() {
        let twelve = (1...12).map { Fixtures.item("\($0)") }
        #expect(idle(rows: twelve) == .list(recent: twelve, canShowMore: true))
        #expect(idle(rows: Array(twelve.prefix(11))) == .list(recent: Array(twelve.prefix(11)), canShowMore: false))
        #expect(idle(rows: twelve, limit: 40) == .list(recent: twelve, canShowMore: false))
    }

    @Test("start here: unpaired, empty, and no space yet")
    func startHere() {
        let empty = HomeList.IdleBody.status(.empty)
        #expect(HomeDerivation.startHere(empty, paired: false, spaces: nil))
        #expect(HomeDerivation.startHere(empty, paired: false, spaces: []))
        #expect(!HomeDerivation.startHere(empty, paired: false, spaces: [Fixtures.space("s", containers: 0, items: 0)]))
        #expect(!HomeDerivation.startHere(empty, paired: true, spaces: []))
        #expect(!HomeDerivation.startHere(.status(.loading), paired: false, spaces: []))
    }

    @Test("the idle stale-data banner: a failed read whose data is on screen, not explained elsewhere")
    func idleRefreshFailed() {
        #expect(HomeDerivation.idleRefreshFailed([(Self.server, true)], connectionIsOnline: true))
        #expect(!HomeDerivation.idleRefreshFailed([(Self.server, false)], connectionIsOnline: true))
        #expect(!HomeDerivation.idleRefreshFailed([(nil, true)], connectionIsOnline: true))
        #expect(!HomeDerivation.idleRefreshFailed([(Self.offline, true)], connectionIsOnline: false))
        #expect(HomeDerivation.idleRefreshFailed([(Self.offline, true)], connectionIsOnline: true))
        #expect(!HomeDerivation.idleRefreshFailed([(Self.revoked, true)], connectionIsOnline: true))
        #expect(HomeDerivation.idleRefreshFailed([(nil, true), (Self.revoked, true), (Self.local, true)], connectionIsOnline: false))
    }

    // MARK: searchBody

    private static let older = Fixtures.results([Fixtures.hit("a")], [Fixtures.place("box")])

    @Test("pending with older results to keep: they stay, and the skeleton mounts above them at 420 ms")
    func pendingWithOlder() {
        let kept = HomeDerivation.searchBody(pending: true, results: Self.older, cause: nil, dim: true, mountSkeleton: false, connectionIsOnline: true)
        #expect(kept == HomeList.resultEntries(Self.older, refreshFailed: false))
        let mounted = HomeDerivation.searchBody(pending: true, results: Self.older, cause: nil, dim: true, mountSkeleton: true, connectionIsOnline: true)
        #expect(mounted == [.status(.searching)] + HomeList.resultEntries(Self.older, refreshFailed: false))
    }

    @Test("pending past 600 ms, or with nothing to keep: the skeleton alone")
    func pendingAlone() {
        #expect(HomeDerivation.searchBody(pending: true, results: Self.older, cause: nil, dim: false, mountSkeleton: true, connectionIsOnline: true) == [.status(.searching)])
        #expect(HomeDerivation.searchBody(pending: true, results: nil, cause: nil, dim: false, mountSkeleton: false, connectionIsOnline: true) == [.status(.searching)])
    }

    @Test("settled without results: the failure, or still searching")
    func noResults() {
        #expect(HomeDerivation.searchBody(pending: false, results: nil, cause: Self.server, dim: false, mountSkeleton: false, connectionIsOnline: true) == [.status(.searchFailed)])
        #expect(HomeDerivation.searchBody(pending: false, results: nil, cause: nil, dim: false, mountSkeleton: false, connectionIsOnline: true) == [.status(.searching)])
    }

    @Test("settled with results: the banner only for a failure nothing else explains")
    func resultsWithBanner() {
        let plain = HomeDerivation.searchBody(pending: false, results: Self.older, cause: nil, dim: false, mountSkeleton: false, connectionIsOnline: true)
        #expect(plain.first?.kind == .summary)
        let failed = HomeDerivation.searchBody(pending: false, results: Self.older, cause: Self.server, dim: false, mountSkeleton: false, connectionIsOnline: true)
        #expect(failed.first?.kind == .refreshFailed)
        let offline = HomeDerivation.searchBody(pending: false, results: Self.older, cause: Self.offline, dim: false, mountSkeleton: false, connectionIsOnline: false)
        #expect(offline.first?.kind == .summary)
        let blip = HomeDerivation.searchBody(pending: false, results: Self.older, cause: Self.offline, dim: false, mountSkeleton: false, connectionIsOnline: true)
        #expect(blip.first?.kind == .refreshFailed)
    }

    @Test("older results are shown only while pending and only when there are any")
    func showingOlder() {
        #expect(HomeDerivation.showingOlder(pending: true, results: Self.older))
        #expect(!HomeDerivation.showingOlder(pending: false, results: Self.older))
        #expect(!HomeDerivation.showingOlder(pending: true, results: nil))
        #expect(!HomeDerivation.showingOlder(pending: true, results: .empty))
    }

    @Test("the search skeleton's wait starts when there is nothing older to keep and no answer")
    func searchStarted() {
        #expect(HomeDerivation.searchStartedActive(searching: true, showingOlder: false, pending: true, hasResults: false))
        #expect(HomeDerivation.searchStartedActive(searching: true, showingOlder: false, pending: false, hasResults: false))
        #expect(!HomeDerivation.searchStartedActive(searching: true, showingOlder: true, pending: true, hasResults: true))
        #expect(!HomeDerivation.searchStartedActive(searching: true, showingOlder: false, pending: false, hasResults: true))
        #expect(!HomeDerivation.searchStartedActive(searching: false, showingOlder: false, pending: false, hasResults: false))
    }

    // MARK: counts

    @Test("the summary counts wait for the spaces and the drop zone")
    func counts() {
        let spaces = [Fixtures.space("a", containers: 4, items: 21), Fixtures.space("b", containers: 9, items: 20)]
        #expect(HomeDerivation.householdCounts(spaces: spaces, dropZoneLoading: false, dropZoneFailed: false, dropZoneCount: 4)
            == HomeList.HouseholdCounts(spaces: 2, containers: 13, items: 45))
        #expect(HomeDerivation.householdCounts(spaces: nil, dropZoneLoading: false, dropZoneFailed: false, dropZoneCount: 0) == nil)
        #expect(HomeDerivation.householdCounts(spaces: spaces, dropZoneLoading: true, dropZoneFailed: false, dropZoneCount: 0) == nil)
        #expect(HomeDerivation.householdCounts(spaces: spaces, dropZoneLoading: false, dropZoneFailed: true, dropZoneCount: 0) == nil)
        #expect(HomeDerivation.householdCounts(spaces: spaces, dropZoneLoading: false, dropZoneFailed: true, dropZoneCount: 2)
            == HomeList.HouseholdCounts(spaces: 2, containers: 13, items: 43))
        #expect(HomeDerivation.householdCounts(spaces: [], dropZoneLoading: false, dropZoneFailed: false, dropZoneCount: 0)
            == HomeList.HouseholdCounts(spaces: 0, containers: 0, items: 0))
    }
}
