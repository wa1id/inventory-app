import InventoryCore
import InventoryStorage
import InventoryStrings
import Observation

/// The reads Home makes, over the local or the household repositories (06 §5.1).
public struct HomeReads: Sendable {
    /// `spaces.listWithCounts()`.
    public var spaces: @Sendable () async throws -> [SpaceWithCounts]
    /// `items.listRecent(limit)`.
    public var recent: @Sendable (Int) async throws -> [ItemWithContext]
    /// `containers.listAllWithSpace()`, for drawing place results.
    public var containers: @Sendable () async throws -> [ContainerWithSpace]
    /// `search.search(trimmed)`.
    public var search: SearchModel.Search

    public init(
        spaces: @escaping @Sendable () async throws -> [SpaceWithCounts],
        recent: @escaping @Sendable (Int) async throws -> [ItemWithContext],
        containers: @escaping @Sendable () async throws -> [ContainerWithSpace],
        search: @escaping SearchModel.Search
    ) {
        self.spaces = spaces
        self.recent = recent
        self.containers = containers
        self.search = search
    }

    /// The reads over a set of repositories.
    public init<Repositories: InventoryRepositories>(repositories: Repositories) {
        self.init(
            spaces: { try await repositories.spaces.listWithCounts() },
            recent: { try await repositories.items.listRecent(limit: $0) },
            containers: { try await repositories.containers.listAllWithSpace() },
            search: { try await repositories.search.search($0) }
        )
    }
}

/// What Home reads from the household and connection models, as closures so this model needs
/// none of their types (observation passes through: a view reading ``HomeModel/paired``
/// re-renders when the session changes).
public struct HomeContext: Sendable {
    /// The joined household's name as stored, or nil when not joined (RN `session?.householdName`).
    public var householdName: @MainActor @Sendable () -> String?
    /// The connection state is exactly `online` (false while local, unsure, offline or revoked).
    public var connectionIsOnline: @MainActor @Sendable () -> Bool
    /// The connection state is `offline` (the banner is up).
    public var connectionIsOffline: @MainActor @Sendable () -> Bool

    public init(
        householdName: @escaping @MainActor @Sendable () -> String?,
        connectionIsOnline: @escaping @MainActor @Sendable () -> Bool,
        connectionIsOffline: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.householdName = householdName
        self.connectionIsOnline = connectionIsOnline
        self.connectionIsOffline = connectionIsOffline
    }

    /// A phone that keeps its own inventory.
    public static let local = HomeContext(householdName: { nil }, connectionIsOnline: { false }, connectionIsOffline: { false })
}

/// Home: her first screen. It answers "where is it?" and "do we still have it?" in place, and
/// shows the household at a glance (RN app/(tabs)/index.tsx; 06 §5).
///
/// One list (``entries``): the search field, then either the overview (the stale-data banner,
/// the unpaired notice, the drop-zone card and Recently added) or the search results in its
/// place. The view renders each ``HomeList/Entry``, and handles what only a view can (keyboard,
/// scrolling, navigation, animation).
///
/// Reads: the spaces (`spaces`), the recent items (`recent:12`, `recent:40` after "Show
/// more"), all containers once the field has been focused or holds a query (`containers-all`,
/// else `containers-none`), the shared drop zone and the search. Each follows focus and the
/// revision like any screen's query.
@MainActor
@Observable
public final class HomeModel {
    public let search: SearchModel
    /// Shared with the tab bar and the Drop zone tab; the tab shell drives its focus.
    public let dropZone: DropZoneModel
    public let spaces: InventoryQuery<[SpaceWithCounts]>
    public let recent: InventoryQuery<[ItemWithContext]>
    public let containers: InventoryQuery<[ContainerWithSpace]>

    /// Older results give way to the skeleton 600 ms after the new query became pending.
    public let dropOlder: DelayedFlag
    /// The skeleton goes in above the older results 180 ms earlier, still invisible, so the
    /// handover has no gap.
    public let mountSkeleton: DelayedFlag
    /// Without older results, the skeleton waits 200 ms from when the search starts.
    public let searchStarted: DelayedFlag

    /// The search field has focus.
    public private(set) var fieldFocused = false
    /// 12, then 40 after "Show more", for the rest of the screen's life.
    public private(set) var recentLimit = HomeList.recentFirst
    /// Containers are read once she heads for the field, and kept fresh from then on.
    public private(set) var wantsPlaces = false
    /// The item whose quantity chip is open; one at a time, closed by any query change.
    public private(set) var expandedId: String?
    /// Bumped when results start (the query went from empty to not): the list jumps to the top.
    public private(set) var scrollToTopRequests = 0
    /// The last recent rows read, kept while a "Show more" read fails (06 §5.1).
    private var shownRecent: [ItemWithContext]?
    /// The unpaired notice was put away; nil until the preference has been read.
    private var noticeDismissed: Bool?

    @ObservationIgnored private var reads: HomeReads
    @ObservationIgnored private let context: HomeContext
    @ObservationIgnored private let unpairedNotice: UnpairedNoticePreference?
    @ObservationIgnored private let rememberCategories: @MainActor @Sendable ([String?]) -> Void

    /// - Parameters:
    ///   - revision: the global revision now.
    ///   - reads: the reads, local or household.
    ///   - dropZone: the shared drop-zone read.
    ///   - context: the household name and the connection state.
    ///   - unpairedNotice: where "Not now" on the unpaired notice is remembered; nil keeps it in memory.
    ///   - clock: the debounce's and the delayed flags' clock.
    ///   - telemetry: where `search_performed` goes.
    ///   - rememberCategories: feeds categories of loaded items to the category memory.
    ///   - announce: speaks the results summary.
    public init(
        revision: Int = 0,
        reads: HomeReads,
        dropZone: DropZoneModel,
        context: HomeContext,
        unpairedNotice: UnpairedNoticePreference?,
        clock: any Clock<Duration> = ContinuousClock(),
        telemetry: TelemetryReporter = .shared,
        rememberCategories: @escaping @MainActor @Sendable ([String?]) -> Void = { _ in },
        announce: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.reads = reads
        self.dropZone = dropZone
        self.context = context
        self.unpairedNotice = unpairedNotice
        self.rememberCategories = rememberCategories
        search = SearchModel(
            revision: revision, clock: clock, telemetry: telemetry,
            rememberCategories: rememberCategories, announce: announce, search: reads.search)
        spaces = InventoryQuery(key: "spaces", revision: revision, read: reads.spaces)
        recent = InventoryQuery(key: Self.recentKey(HomeList.recentFirst), revision: revision, read: Self.recentRead(reads, HomeList.recentFirst))
        containers = InventoryQuery(key: "containers-none", revision: revision, read: Self.noContainers)
        dropOlder = DelayedFlag(delay: .milliseconds(Motion.delay.searchSkeleton), clock: clock)
        mountSkeleton = DelayedFlag(delay: .milliseconds(Motion.delay.searchSkeleton - Motion.delay.skeleton), clock: clock)
        searchStarted = DelayedFlag(delay: .milliseconds(Motion.delay.searchDebounce), clock: clock)
        recent.onSettle = { [weak self] in self?.recentSettled() }
        search.onSettle = { [weak self] in self?.updateDelayedFlags() }
    }

    // MARK: Inputs

    /// Home gained or lost focus (or a sheet went over it).
    public func focusChanged(_ focused: Bool, revision: Int? = nil) {
        if focused && noticeDismissed == nil {
            noticeDismissed = unpairedNotice?.isDismissed ?? false
        }
        spaces.focusChanged(focused, revision: revision)
        recent.focusChanged(focused, revision: revision)
        containers.focusChanged(focused, revision: revision)
        search.focusChanged(focused, revision: revision)
    }

    /// The global revision changed.
    public func revisionChanged(_ revision: Int) {
        spaces.revisionChanged(revision)
        recent.revisionChanged(revision)
        containers.revisionChanged(revision)
        search.revisionChanged(revision)
    }

    /// The field's text changed (a write of the same text is not a change).
    public func setQuery(_ text: String) {
        guard !text.utf16.elementsEqual(query.utf16) else { return }
        let wasSearching = isSearching
        search.setQuery(text)
        if isSearching && !wasSearching { scrollToTopRequests += 1 }
        // A new list starts with every chip closed.
        expandedId = nil
        latchPlaces()
        updateDelayedFlags()
    }

    /// The field gained or lost focus.
    public func setFieldFocused(_ focused: Bool) {
        fieldFocused = focused
        latchPlaces()
    }

    /// "Show more": forty recent items; the twelve stay on screen meanwhile.
    public func showMore() {
        guard recentLimit != HomeList.recentMore else { return }
        recentLimit = HomeList.recentMore
        recent.setKey(Self.recentKey(recentLimit), read: Self.recentRead(reads, recentLimit))
    }

    /// Opens an item's quantity chip, or closes it when it is the open one.
    public func toggleExpand(_ id: String) {
        expandedId = expandedId == id ? nil : id
    }

    /// Closes the open quantity chip.
    public func collapse() {
        expandedId = nil
    }

    /// "Not now" on the unpaired notice: hidden at once, remembered on this phone.
    public func dismissNotice() {
        noticeDismissed = true
        unpairedNotice?.dismiss()
    }

    /// The search key.
    public func submitSearch() {
        search.submit()
    }

    /// Reads the overview again: spaces, recent items and the drop zone (the error state's Try again).
    public func reloadOverview() {
        spaces.reload()
        recent.reload()
        dropZone.reload()
    }

    /// The stale-data banner's Try again: the search while searching, else the overview.
    public func retry() {
        if isSearching { search.retry() } else { reloadOverview() }
    }

    /// Pull to refresh: the overview and, while searching, the search and the containers
    /// (place rows take their codes and types from them). Returns once all have answered.
    public func refresh() async {
        let searching = isSearching
        async let spacesRead: Void = spaces.refresh()
        async let recentRead: Void = recent.refresh()
        async let dropZoneRead: Void = dropZone.refresh()
        if searching {
            async let searchRead: Void = search.refresh()
            async let containersRead: Void = containers.refresh()
            _ = await (searchRead, containersRead)
        }
        _ = await (spacesRead, recentRead, dropZoneRead)
    }

    /// The repositories changed (joined or left). Nothing is read until the caller invalidates.
    public func setReads(_ reads: HomeReads) {
        self.reads = reads
        spaces.setRead(reads.spaces)
        recent.setRead(Self.recentRead(reads, recentLimit))
        containers.setRead(wantsPlaces ? reads.containers : Self.noContainers)
        search.setSearch(reads.search)
    }

    // MARK: Outputs

    /// The field's text.
    public var query: String { search.query }
    /// The query trimmed.
    public var trimmedQuery: String { search.trimmed }
    /// Something is typed: results replace the overview.
    public var isSearching: Bool { search.isSearching }
    /// The title block goes while the field is focused or holds a query.
    public var isCompact: Bool { fieldFocused || isSearching }

    /// Joined to a household.
    public var paired: Bool { context.householdName() != nil }

    /// The title: the household's name, or `L10n.Home.title` when it has none or there is none.
    public var title: String {
        let name = context.householdName()?.jsTrimmed() ?? ""
        return name.isEmpty ? L10n.Home.title : name
    }

    /// The household summary's counts (see ``HomeDerivation/householdCounts(spaces:dropZoneLoading:dropZoneFailed:dropZoneCount:)``).
    public var counts: HomeList.HouseholdCounts? {
        HomeDerivation.householdCounts(
            spaces: spaces.data,
            dropZoneLoading: dropZone.loading,
            dropZoneFailed: dropZone.cause != nil,
            dropZoneCount: dropZone.count)
    }

    /// Subtitle line 1, "5 spaces, 13 containers and 45 items.", or nil: an empty household's
    /// zeros would only repeat the empty state below.
    public var summaryLine: String? {
        guard let counts, counts.spaces + counts.items > 0 else { return nil }
        return counts.summary
    }

    /// Joined and the home server is not answering: line 2 and its icon turn signal.
    public var reconnecting: Bool { paired && context.connectionIsOffline() }

    /// Subtitle line 2, where the data lives (always shown).
    public var whereLine: String {
        if reconnecting { return L10n.Connection.sharedReconnecting }
        return paired ? L10n.Connection.shared : L10n.Connection.local
    }

    /// The recent rows on screen: the newest read, else the last one that answered.
    public var recentRows: [ItemWithContext]? { recent.data ?? shownRecent }

    /// The "This phone keeps its own inventory" notice may show (not joined, not put away).
    public var noticeVisible: Bool { !paired && noticeDismissed == false }

    public var idleBody: HomeList.IdleBody {
        HomeDerivation.idleBody(
            recentRows: recentRows,
            recentFailed: recent.cause != nil,
            dropZoneCount: dropZone.count,
            paired: paired,
            spacesLoaded: spaces.data != nil,
            spacesFailed: spaces.cause != nil,
            recentLimit: recentLimit)
    }

    /// The empty household offers to join or start with a space.
    public var startHere: Bool {
        HomeDerivation.startHere(idleBody, paired: paired, spaces: spaces.data)
    }

    /// Older results are on screen, dimmed, not tappable and hidden from VoiceOver.
    public var dim: Bool {
        HomeDerivation.showingOlder(pending: search.pending, results: search.results) && !dropOlder.value
    }

    /// The `searching` status shows its skeleton.
    public var searchSkeletonVisible: Bool { searchStarted.value || mountSkeleton.value }

    /// The whole list.
    public var entries: [HomeList.Entry] {
        let online = context.connectionIsOnline()
        if isSearching {
            return [.field] + HomeDerivation.searchBody(
                pending: search.pending,
                results: search.results,
                cause: search.cause,
                dim: dim,
                mountSkeleton: mountSkeleton.value,
                connectionIsOnline: online)
        }
        let rows = recentRows
        let refreshFailed = HomeDerivation.idleRefreshFailed(
            [
                (spaces.cause, spaces.data != nil),
                (recent.cause, rows != nil),
                (dropZone.cause, dropZone.count > 0),
            ],
            connectionIsOnline: online)
        let body = idleBody
        return [.field] + HomeList.idleEntries(HomeList.IdleInput(
            // The empty household already offers to join; the notice would repeat it.
            notice: noticeVisible && !HomeDerivation.startHere(body, paired: paired, spaces: spaces.data),
            refreshFailed: refreshFailed,
            dropZoneCount: dropZone.count,
            body: body))
    }

    /// The overview's failure, for the `error` status.
    public var overviewCause: (any Error)? { recent.cause ?? spaces.cause }

    /// The `error` status says "waiting for the home server" instead of an error state: the
    /// connection banner already explains it and offers the one Try again.
    public var overviewWaitingForServer: Bool {
        guard let overviewCause else { return false }
        return HomeDerivation.explainedElsewhere(overviewCause, connectionIsOnline: context.connectionIsOnline())
    }

    /// The search error state's title: the offline wording when the home server did not
    /// answer, else `L10n.Search.failed`; the body is the described one.
    public var searchFailedCopy: ErrorCopy? {
        guard let cause = search.cause else { return nil }
        let described = describeError(cause)
        return described.kind == .offline ? described : ErrorCopy(kind: described.kind, title: L10n.Search.failed, body: described.body)
    }

    /// Terms to mark in item rows (only while searching) and place rows.
    public var highlightTerms: [String] { isSearching ? search.results?.terms ?? [] : [] }

    /// Place results draw from these; a hit without its record falls back to a plain row.
    public var spacesById: [String: SpaceWithCounts] {
        Dictionary((spaces.data ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// See ``spacesById``.
    public var containersById: [String: ContainerWithSpace] {
        Dictionary((containers.data ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// The pull-to-refresh spinner's condition: a list it asked for has not answered yet.
    public var refreshing: Bool {
        spaces.isLoading || recent.isLoading || (isSearching && search.refreshing)
    }

    // MARK: Reactions

    private static func recentKey(_ limit: Int) -> String { "recent:\(limit)" }

    /// The read under `containers-none`, before she heads for the field.
    private nonisolated static let noContainers: @Sendable () async throws -> [ContainerWithSpace] = { [] }

    private static func recentRead(_ reads: HomeReads, _ limit: Int) -> @Sendable () async throws -> [ItemWithContext] {
        let recent = reads.recent
        return { try await recent(limit) }
    }

    private func latchPlaces() {
        guard isCompact, !wantsPlaces else { return }
        wantsPlaces = true
        containers.setKey("containers-all", read: reads.containers)
    }

    private func recentSettled() {
        guard let data = recent.data else { return }
        if recent.cause == nil { rememberCategories(data.map(\.item.category)) }
        shownRecent = data
    }

    private func updateDelayedFlags() {
        let older = HomeDerivation.showingOlder(pending: search.pending, results: search.results)
        dropOlder.setActive(older)
        mountSkeleton.setActive(older)
        searchStarted.setActive(HomeDerivation.searchStartedActive(
            searching: isSearching, showingOlder: older, pending: search.pending, hasResults: search.results != nil))
    }
}
