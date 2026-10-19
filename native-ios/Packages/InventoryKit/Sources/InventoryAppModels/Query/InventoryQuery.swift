import Observation

/// What a query's current read is for: its inputs, the revision the screen has caught up with
/// and its own reload counter (RN's `requestToken`, `FNV-1a("key|seenRevision|localRevision")`,
/// src/hooks/useInventoryQuery.ts:71,130-138, without the hashing). A read runs exactly when
/// this changes.
public struct QueryTrigger: Hashable, Sendable {
    /// The identity of the query's inputs, e.g. `space:<id>` (01 §9.1 lists the keys in use).
    public var key: String
    /// The global revision as of the last time the screen was focused, or of the last write
    /// while it was.
    public var seenRevision: Int
    /// Bumped on every focus gain and on `reload()`.
    public var localRevision: Int

    public init(key: String, seenRevision: Int, localRevision: Int) {
        self.key = key
        self.seenRevision = seenRevision
        self.localRevision = localRevision
    }
}

/// One screen's read of the inventory, kept fresh by the global revision and by focus
/// (RN `useInventoryQuery`, src/hooks/useInventoryQuery.ts; 09 §5, 01 §9.1, 06 §16.1).
///
/// The read re-runs when the screen gains focus, when the revision changes while the screen is
/// focused (a screen behind catches up when it is focused again), when the key changes and on
/// ``reload()``. It works the same over local SQLite and over household HTTP, which is why the
/// app keeps this design rather than database observation (DECISIONS D-6).
///
/// The view drives it: ``focusChanged(_:revision:)`` from the screen's focus (top of its
/// stack, its tab selected, no sheet over it; a screen under a sheet is unfocused, 00 §5),
/// ``revisionChanged(_:)`` from `DatabaseModel.revision`, ``setKey(_:)`` when its inputs
/// change and ``reload()`` for Try again.
///
/// Native differences from RN, both deliberate (09 §5 "quirks not to copy"): exactly one read
/// per trigger change, so appearing focused reads once (RN read twice on mount) and gaining
/// focus after a write reads once (RN read twice); and nothing is read until the screen is
/// first focused, a key changes or ``reload()`` runs.
///
/// Outputs, exactly as RN computes them:
/// - ``data``: the last settled value, **not filtered by key**: while a new key loads, the
///   previous key's data stays (Home keeps "Show more" rows this way, 06 §5.1). A failure keeps
///   the data only when it was read for the same key, otherwise it becomes `nil`.
/// - ``isLoading``: the newest trigger has not settled.
/// - ``cause``: what the newest read threw, only once it has settled; `nil` means "no error".
///   A read that answered `nil` ("gone") is data, not a cause: never pass a `nil` cause to
///   `describeError` for the gone case, pass `nil` deliberately from the screen's own branch
///   (09 §5 cause semantics).
/// - ``refreshFailed``: the newest read failed while data stays on screen.
@MainActor
@Observable
public final class InventoryQuery<Value: Sendable> {
    /// The read: a repository call, local or household.
    public typealias Read = @Sendable () async throws -> Value

    /// The newest settled read (RN `Settled`).
    private struct Settled {
        /// The trigger it answered; nil before the first read settles (RN token -1).
        var trigger: QueryTrigger?
        /// The key it was read for, so a failure keeps only this key's data.
        var key: String
        var data: Value?
        var failed: Bool
        var cause: (any Error)?
    }

    /// The inputs of the read that is running or ran last.
    public private(set) var trigger: QueryTrigger
    /// Whether the screen is focused, as the view last said.
    public private(set) var isFocused = false
    private var settled: Settled

    /// The newest global revision the view reported.
    @ObservationIgnored private var revision: Int
    @ObservationIgnored private var read: Read
    /// Bumped per read, so an answer from a superseded read (even one whose trigger has since
    /// come back, key A → B → A) is ignored, as RN's per-effect `cancelled` flag ignored it.
    @ObservationIgnored private var generation = 0
    /// The running read. Tests and ``refresh()`` await it.
    @ObservationIgnored private(set) var readTask: Task<Void, Never>?
    /// How many reads started, for tests.
    @ObservationIgnored private(set) var readCount = 0
    /// Called after every applied answer, for a model that reacts to new data.
    @ObservationIgnored var onSettle: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - key: the identity of the read's inputs.
    ///   - revision: the global revision now (RN `seenRevision` starts at it on mount).
    ///   - read: the read; replaced with ``setRead(_:)`` or ``setKey(_:read:)``.
    public init(key: String, revision: Int = 0, read: @escaping Read) {
        trigger = QueryTrigger(key: key, seenRevision: revision, localRevision: 0)
        settled = Settled(trigger: nil, key: key, data: nil, failed: false, cause: nil)
        self.revision = revision
        self.read = read
    }

    // MARK: Outputs

    /// The query's current key.
    public var key: String { trigger.key }

    /// The last settled value, kept across refreshes (see the type's notes on keys).
    public var data: Value? { settled.data }

    /// The key ``data`` was read for, or nil before anything settled.
    public var dataKey: String? { settled.trigger == nil ? nil : settled.key }

    /// The newest read has not settled yet (RN `loading`).
    public var isLoading: Bool { settled.trigger != trigger }

    /// Why the newest read failed, once it has; nil while it runs and when it worked.
    public var cause: (any Error)? {
        isCurrent && settled.failed ? settled.cause : nil
    }

    /// The newest read failed but earlier data is still on screen (RN `failed && data !== null`).
    ///
    /// A value that is itself `nil` (a read that found the record gone) counts as no data here,
    /// as JS `null` did, so the screen shows its error state rather than a stale "gone".
    public var refreshFailed: Bool {
        isCurrent && settled.failed && Self.isPresent(settled.data)
    }

    private var isCurrent: Bool { settled.trigger == trigger }

    // MARK: Inputs

    /// The screen gained or lost focus. Gaining it catches up with `revision` (or the last
    /// revision reported) and reloads, as one read.
    public func focusChanged(_ focused: Bool, revision: Int? = nil) {
        if let revision { self.revision = revision }
        let gained = focused && !isFocused
        isFocused = focused
        if gained {
            let caughtUp = self.revision
            update { trigger in
                trigger.seenRevision = caughtUp
                trigger.localRevision += 1
            }
        } else if focused {
            catchUp()
        }
    }

    /// The global revision changed (a write somewhere). Read again only while focused.
    public func revisionChanged(_ revision: Int) {
        self.revision = revision
        if isFocused { catchUp() }
    }

    /// The query's inputs changed: read for the new key, focused or not (RN re-ran on a key change).
    public func setKey(_ key: String) {
        update { $0.key = key }
    }

    /// The inputs and the read changed together.
    public func setKey(_ key: String, read: @escaping Read) {
        self.read = read
        setKey(key)
    }

    /// Replaces the read without reading: RN kept the latest closure in a ref, so a new closure
    /// with the same key did not re-run the query; callers invalidate after pairing or leaving.
    public func setRead(_ read: @escaping Read) {
        self.read = read
    }

    /// Reads again (Try again, pull to refresh).
    public func reload() {
        update { $0.localRevision += 1 }
    }

    /// Reads again and returns once that read has settled (`.refreshable`).
    public func refresh() async {
        reload()
        await readTask?.value
    }

    // MARK: Reading

    private func catchUp() {
        let caughtUp = revision
        update { $0.seenRevision = caughtUp }
    }

    private func update(_ change: (inout QueryTrigger) -> Void) {
        var next = trigger
        change(&next)
        guard next != trigger else { return }
        trigger = next
        startRead()
    }

    private func startRead() {
        readTask?.cancel()
        generation &+= 1
        readCount += 1
        let generation = self.generation
        let trigger = self.trigger
        let read = self.read
        readTask = Task { [weak self] in
            let outcome: Result<Value, any Error>
            do {
                outcome = .success(try await read())
            } catch {
                outcome = .failure(error)
            }
            self?.settle(outcome, for: trigger, generation: generation)
        }
    }

    private func settle(_ outcome: Result<Value, any Error>, for trigger: QueryTrigger, generation: Int) {
        guard generation == self.generation else { return }
        switch outcome {
        case .success(let value):
            settled = Settled(trigger: trigger, key: trigger.key, data: value, failed: false, cause: nil)
        case .failure(let error):
            // A blip never turns a list into an error page, but another key's data is not kept.
            let kept = settled.key == trigger.key ? settled.data : nil
            settled = Settled(trigger: trigger, key: trigger.key, data: kept, failed: true, cause: error)
        }
        onSettle?()
    }

    /// JS `data !== null`, looking through a value that is itself optional.
    private static func isPresent(_ data: Value?) -> Bool {
        guard let data else { return false }
        if let nullable = data as? any InventoryQueryNullable { return !nullable.isQueryNull }
        return true
    }
}

/// Lets ``InventoryQuery`` see a `nil` inside an optional value, which JS kept as `null`.
protocol InventoryQueryNullable {
    var isQueryNull: Bool { get }
}

extension Optional: InventoryQueryNullable {
    var isQueryNull: Bool { self == nil }
}
