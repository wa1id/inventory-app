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
/// - Native only: a query that finds nothing has its unknown words corrected against the
///   inventory's own words (``SearchSpelling``) and is searched again; when that finds
///   something, it is the answer, with ``correction`` saying what was searched instead.
///
/// Strings compare as JS compares them (by UTF-16 code units).
@MainActor
@Observable
public final class SearchModel {
    /// The search itself: `repositories.search.search(trimmed)`, local or household.
    public typealias Search = @Sendable (String) async throws -> SearchResults
    /// The words the inventory uses, for correcting a query that found nothing.
    public typealias Vocabulary = @Sendable () async throws -> SearchVocabulary

    /// A query that found nothing, answered by a corrected one (native only).
    public struct Correction: Sendable, Hashable {
        /// The query as typed (trimmed).
        public var typed: String
        /// The corrected query searched instead.
        public var shown: String

        public init(typed: String, shown: String) {
            self.typed = typed
            self.shown = shown
        }
    }

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
        /// Set when ``results`` answer a corrected query.
        var correction: Correction?
        var cause: (any Error)?
    }

    private struct Answer {
        var results: SearchResults
        var correction: Correction?
    }

    /// The field's text.
    public private(set) var query = ""
    /// `query` trimmed as JS `trim()` trims it; empty means no search.
    public private(set) var trimmed = ""
    /// Whether Home is focused, as last reported.
    public private(set) var isFocused = false
    public private(set) var run: Run
    private var settled = Settled(query: "", run: nil, results: nil, correction: nil, cause: nil)

    @ObservationIgnored private var revision: Int
    @ObservationIgnored private var search: Search
    @ObservationIgnored private var vocabulary: Vocabulary?
    /// The words last read, and the revision they were read at.
    @ObservationIgnored private var vocabularyCache: (revision: Int, words: SearchVocabulary)?
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
    ///   - vocabulary: the inventory's words, read when a query finds nothing; nil corrects nothing.
    ///   - search: the search.
    public init(
        revision: Int = 0,
        clock: any Clock<Duration> = ContinuousClock(),
        telemetry: TelemetryReporter = .shared,
        rememberCategories: @escaping @MainActor @Sendable ([String?]) -> Void = { _ in },
        announce: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        vocabulary: Vocabulary? = nil,
        search: @escaping Search
    ) {
        self.revision = revision
        run = Run(seenRevision: revision, nonce: 0)
        self.clock = clock
        self.telemetry = telemetry
        self.rememberCategories = rememberCategories
        self.announce = announce
        self.vocabulary = vocabulary
        self.search = search
    }

    // MARK: Outputs

    /// The query ``results`` belong to: `""` until a search has finished.
    public var settledQuery: String { settled.query }

    /// Results for ``settledQuery``, kept while it runs again and when a re-run fails; they may
    /// belong to an older query (see ``pending``).
    public var results: SearchResults? { settled.results }

    /// What was searched instead when ``results`` answer a corrected query; nil otherwise.
    public var correction: Correction? { settled.correction }

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
        announce(Self.summary(results, correction: settled.correction))
    }

    /// The repositories changed (joined or left): later searches use `search` and `vocabulary`.
    public func setSearch(_ search: @escaping Search, vocabulary: Vocabulary? = nil) {
        self.search = search
        self.vocabulary = vocabulary
        vocabularyCache = nil
    }

    /// `L10n.Search.summary` for a result set (items and places), after what was searched
    /// instead when the query was corrected.
    public nonisolated static func summary(_ results: SearchResults, correction: Correction? = nil) -> String {
        let found = L10n.Search.summary(items: results.items.count, places: results.locations.count)
        guard let correction else { return found }
        return L10n.Search.Corrected.showing(typed: correction.typed, shown: correction.shown) + " " + found
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
            let outcome: Result<Answer, any Error>
            do {
                var answer = Answer(results: try await search(query))
                if Self.isEmpty(answer.results),
                   let shown = await self?.correctedQuery(for: query, revision: run.seenRevision),
                   let found = try? await search(shown), !Self.isEmpty(found) {
                    answer = Answer(results: found, correction: Correction(typed: query, shown: shown))
                }
                outcome = .success(answer)
            } catch {
                outcome = .failure(error)
            }
            self?.settle(outcome, query: query, run: run, generation: generation)
        }
    }

    private nonisolated static func isEmpty(_ results: SearchResults) -> Bool {
        results.items.isEmpty && results.locations.isEmpty
    }

    /// The query to search instead of `query`, which found nothing, from the words read at
    /// `revision` (read again once the revision moves on); nil without a vocabulary, when it
    /// cannot be read, or when nothing needs correcting.
    private func correctedQuery(for query: String, revision: Int) async -> String? {
        guard let vocabulary else { return nil }
        let words: SearchVocabulary
        if let cached = vocabularyCache, cached.revision == revision {
            words = cached.words
        } else {
            guard let read = try? await vocabulary() else { return nil }
            vocabularyCache = (revision, read)
            words = read
        }
        // Comparing against every known word is kept off the main actor.
        return await Task.detached(priority: .userInitiated) {
            SearchSpelling.correctedQuery(query, vocabulary: words)
        }.value
    }

    /// Counts a search that reached the repository; false when it was superseded meanwhile.
    private func started(_ generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        searchCount += 1
        return true
    }

    private func settle(_ outcome: Result<Answer, any Error>, query: String, run: Run, generation: Int) {
        guard generation == self.generation else { return }
        switch outcome {
        case .success(let answer):
            let found = answer.results
            settled = Settled(query: query, run: run, results: found, correction: answer.correction, cause: nil)
            rememberCategories(found.items.map { $0.item.item.category })
            if !Self.same(loggedQuery, query) {
                loggedQuery = query
                var payload: TelemetryPayload = [
                    "termCount": .int(found.terms.count),
                    "resultCount": .int(found.items.count + found.locations.count),
                    "queryLength": .int(query.utf16.count),
                ]
                if answer.correction != nil { payload["outcome"] = .string("corrected") }
                telemetry.event("search_performed", payload)
            }
        case .failure(let error):
            let same = Self.same(settled.query, query)
            settled = Settled(
                query: query, run: run, results: same ? settled.results : nil,
                correction: same ? settled.correction : nil, cause: error)
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
            announce(Self.summary(results, correction: settled.correction))
        } else if cause != nil {
            announceWhenSettled = false
        }
    }

    /// JS `===` on strings: the same UTF-16 code units.
    private static func same(_ a: String, _ b: String) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }
}
