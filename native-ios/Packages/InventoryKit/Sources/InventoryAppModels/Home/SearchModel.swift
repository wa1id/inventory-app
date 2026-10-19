import InventoryCore
import InventoryStrings
import Observation

/// Home's search: what she types, matched against names, places and the codes written on
/// labels (RN `useSearch`, src/hooks/useSearch.ts; 06 §5.6, §5.10, 01 §9.2).
///
/// - A new query waits for a 200 ms pause in typing (`Motion.delay.searchDebounce`); the same
///   query run again (focus, a write, Try again) starts at once. Every change cancels the
///   waiting timer and ignores the answer in flight.
/// - Results always belong to a query (``settledQuery``), so ``pending`` is derived: results
///   for an older query are never shown as the answer to the current one. They are kept when
///   the field is emptied, so the last results show dimmed while new words settle.
/// - The current query runs again when Home gains focus and after any write while Home is
///   focused; Home catches up with writes made elsewhere when it is focused again.
/// - A failed re-run keeps the results it had for the same query.
/// - `search_performed {termCount, resultCount, queryLength}` is logged once per settled query
///   (again after the field has been emptied); the text is never logged.
/// - The summary is spoken when she presses the search key (``submit()``), or when the
///   results arrive if she pressed it before they did.
///
/// Strings compare as JS compares them (by UTF-16 code units).
@MainActor
@Observable
public final class SearchModel {
    /// The search itself: `repositories.search.search(trimmed)`, local or household.
    public typealias Search = @Sendable (String) async throws -> SearchResults

    /// Which run of a query answered: the revision and nonce it was read at (RN `run`).
    public struct Run: Hashable, Sendable {
        public var seenRevision: Int
        public var nonce: Int
    }

    private struct Settled {
        var query: String
        /// Nil until something settles (RN `''`, which no run equals).
        var run: Run?
        var results: SearchResults?
        var cause: (any Error)?
    }

    /// The field's text.
    public private(set) var query = ""
    /// `query` trimmed as JS `trim()` trims it; empty means no search.
    public private(set) var trimmed = ""
    /// Whether Home is focused, as last reported.
    public private(set) var isFocused = false
    public private(set) var run: Run
    private var settled = Settled(query: "", run: nil, results: nil, cause: nil)

    @ObservationIgnored private var revision: Int
    @ObservationIgnored private var search: Search
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let telemetry: TelemetryReporter
    @ObservationIgnored private let rememberCategories: @MainActor @Sendable ([String?]) -> Void
    @ObservationIgnored private let announce: @MainActor @Sendable (String) -> Void
    @ObservationIgnored private var loggedQuery = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var announceWhenSettled = false
    /// The waiting or running search. Tests and ``refresh()`` await it.
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    /// How many searches reached the repository, for tests.
    @ObservationIgnored private(set) var searchCount = 0
    /// Called after every settled answer, for a model that derives timers from the results.
    @ObservationIgnored var onSettle: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - revision: the global revision now.
    ///   - clock: the debounce's clock.
    ///   - telemetry: where `search_performed` goes.
    ///   - rememberCategories: feeds the categories of found items to the category memory
    ///     (`CategoryMemory.rememberCategories`).
    ///   - announce: speaks the results summary (a VoiceOver announcement).
    ///   - search: the search.
    public init(
        revision: Int = 0,
        clock: any Clock<Duration> = ContinuousClock(),
        telemetry: TelemetryReporter = .shared,
        rememberCategories: @escaping @MainActor @Sendable ([String?]) -> Void = { _ in },
        announce: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        search: @escaping Search
    ) {
        self.revision = revision
        run = Run(seenRevision: revision, nonce: 0)
        self.clock = clock
        self.telemetry = telemetry
        self.rememberCategories = rememberCategories
        self.announce = announce
        self.search = search
    }

    // MARK: Outputs

    /// The query ``results`` belong to: `""` until a search has finished.
    public var settledQuery: String { settled.query }

    /// Results for ``settledQuery``, kept while it runs again and when a re-run fails; they may
    /// belong to an older query (see ``pending``).
    public var results: SearchResults? { settled.results }

    /// Why the newest run of the current query failed, once it has; nil otherwise.
    public var cause: (any Error)? { isAnswered ? settled.cause : nil }

    /// The results do not belong to what is in the field yet: she is typing, or the new query
    /// is in flight. Older results must not look current.
    public var pending: Bool { !trimmed.isEmpty && !isCurrent }

    /// The current query is running again (Home refocused, a write, Try again).
    public var refreshing: Bool { isCurrent && !isAnswered }

    /// Something is typed.
    public var isSearching: Bool { !trimmed.isEmpty }

    private var isCurrent: Bool { !trimmed.isEmpty && Self.same(settled.query, trimmed) }
    private var isAnswered: Bool { isCurrent && settled.run == run }

    // MARK: Inputs

    /// The field's text changed. Takes back a summary still waiting to be said.
    public func setQuery(_ text: String) {
        guard !Self.same(text, query) else { return }
        query = text
        announceWhenSettled = false
        let next = text.jsTrimmed()
        guard !Self.same(next, trimmed) else { return }
        trimmed = next
        restart()
    }

    /// Home gained or lost focus. Gaining it runs the current query again, caught up with
    /// `revision` (or the last revision reported), as one run.
    public func focusChanged(_ focused: Bool, revision: Int? = nil) {
        if let revision { self.revision = revision }
        let gained = focused && !isFocused
        isFocused = focused
        if gained {
            run = Run(seenRevision: self.revision, nonce: run.nonce + 1)
            restart()
        } else if focused {
            catchUp()
        }
    }

    /// The global revision changed: run again only while Home is focused.
    public func revisionChanged(_ revision: Int) {
        self.revision = revision
        if isFocused { catchUp() }
    }

    /// Runs the current query again ("Try again").
    public func retry() {
        run.nonce += 1
        restart()
    }

    /// Runs the current query again and returns once it has settled (pull to refresh).
    public func refresh() async {
        retry()
        await searchTask?.value
    }

    /// The search key: speak the summary now, or when the results arrive. Nothing for an
    /// empty field (the last search's results are still held, but they are not an answer).
    public func submit() {
        guard isSearching else { return }
        guard !pending, let results else {
            announceWhenSettled = true
            return
        }
        announce(Self.summary(results))
    }

    /// The repositories changed (joined or left): later searches use `search`.
    public func setSearch(_ search: @escaping Search) {
        self.search = search
    }

    /// `L10n.Search.summary` for a result set (items and places).
    public nonisolated static func summary(_ results: SearchResults) -> String {
        L10n.Search.summary(items: results.items.count, places: results.locations.count)
    }

    // MARK: Running

    private func catchUp() {
        guard run.seenRevision != revision else { return }
        run.seenRevision = revision
        restart()
    }

    private func restart() {
        searchTask?.cancel()
        searchTask = nil
        generation &+= 1
        let query = trimmed
        guard !query.isEmpty else {
            // Searching the same words again later is a new search.
            loggedQuery = ""
            return
        }
        let wait: Duration = Self.same(query, settled.query) ? .zero : .milliseconds(Motion.delay.searchDebounce)
        let run = run
        let search = search
        let generation = generation
        searchTask = Task { [weak self, clock] in
            if wait > .zero {
                do { try await clock.sleep(for: wait) } catch { return }
            }
            guard let started = self?.started(generation), started else { return }
            let outcome: Result<SearchResults, any Error>
            do {
                outcome = .success(try await search(query))
            } catch {
                outcome = .failure(error)
            }
            self?.settle(outcome, query: query, run: run, generation: generation)
        }
    }

    /// Counts a search that reached the repository; false when it was superseded meanwhile.
    private func started(_ generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        searchCount += 1
        return true
    }

    private func settle(_ outcome: Result<SearchResults, any Error>, query: String, run: Run, generation: Int) {
        guard generation == self.generation else { return }
        switch outcome {
        case .success(let found):
            settled = Settled(query: query, run: run, results: found, cause: nil)
            rememberCategories(found.items.map { $0.item.item.category })
            if !Self.same(loggedQuery, query) {
                loggedQuery = query
                telemetry.event("search_performed", [
                    "termCount": .int(found.terms.count),
                    "resultCount": .int(found.items.count + found.locations.count),
                    "queryLength": .int(query.utf16.count),
                ])
            }
        case .failure(let error):
            let kept = Self.same(settled.query, query) ? settled.results : nil
            settled = Settled(query: query, run: run, results: kept, cause: error)
        }
        announceIfWaiting()
        onSettle?()
    }

    /// Says the summary that ``submit()`` left waiting, now that the query has settled; a failure
    /// takes it back (the error state announces itself).
    private func announceIfWaiting() {
        guard announceWhenSettled, !pending else { return }
        if let results {
            announceWhenSettled = false
            announce(Self.summary(results))
        } else if cause != nil {
            announceWhenSettled = false
        }
    }

    /// JS `===` on strings: the same UTF-16 code units.
    private static func same(_ a: String, _ b: String) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }
}
