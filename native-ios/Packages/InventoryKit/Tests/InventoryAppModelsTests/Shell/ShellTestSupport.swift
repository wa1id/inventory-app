import Foundation
import InventoryCore
import InventoryTestSupport
import Synchronization
import Testing

// Test helpers for the Shell, Query and Home suites. Every top-level name starts with `Shell`
// so it never collides with another area's helpers in this target.

/// A failure a fake read throws, with the household error types `describeError` classifies.
struct ShellTestError: Error, Equatable {
    let name: String
    init(_ name: String = "boom") { self.name = name }
}

/// Polls a main-actor condition until it holds, yielding to the tasks under test.
enum ShellWait {
    /// Returns once `condition` is true; records an issue after `timeout` of real time.
    @MainActor
    static func until(
        _ description: String = "condition",
        timeout: Duration = .seconds(60),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now > deadline {
                Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Lets the tasks the code under test just started run to their next suspension point.
    static func settle() async {
        for _ in 0..<20 {
            await Task.detached(priority: .background) { await Task.yield() }.value
            await Task.yield()
        }
    }
}

/// A clock whose sleepers wake only when the test calls ``fire(throughMilliseconds:)``, which
/// resumes them synchronously and returns before they run.
///
/// `ManualClock.advance` lets each woken task run before it returns; this one leaves a gap, so
/// a main-actor test can act after a timer's sleep has ended but before the timer's task runs:
/// the window in which cancelling the task no longer stops its sleep, and only a check of
/// `Task.isCancelled` after the sleep keeps a replaced timer from acting.
final class ShellStepClock: Clock, Sendable {
    typealias Instant = ManualClock.Instant

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        /// Ids whose task was cancelled before its continuation was registered.
        var cancelledEarly: Set<UInt64> = []
    }

    private let state = Mutex(State())

    init() {}

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    /// How many tasks are asleep on this clock.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelledEarly.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                    return state.sleepers.remove(at: index)
                }
                state.cancelledEarly.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time to `ms` after the start and ends every sleep due by then, without waiting for
    /// the sleepers to run. Returns how many it woke.
    @discardableResult
    func fire(throughMilliseconds ms: Int) -> Int {
        let target = Instant(offset: .milliseconds(ms))
        let due: [Sleeper] = state.withLock { state in
            if state.now < target { state.now = target }
            let due = state.sleepers.filter { $0.deadline <= target }
            state.sleepers.removeAll { $0.deadline <= target }
            return due
        }
        due.forEach { $0.continuation.resume() }
        return due.count
    }
}

/// A read whose calls each wait until the test answers them, in any order.
final class ShellHeldReads<Value: Sendable>: Sendable {
    private struct State {
        var calls: [String] = []
        var waiting: [Int: CheckedContinuation<Value, any Error>] = [:]
    }

    private let state = Mutex(State())

    init() {}

    /// A read for `InventoryQuery`.
    var read: @Sendable () async throws -> Value {
        { try await self.call("") }
    }

    /// A read that records its argument (a search query, a recent limit).
    func call(_ argument: String) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                state.waiting[state.calls.count] = continuation
                state.calls.append(argument)
            }
        }
    }

    /// How many calls were made.
    var callCount: Int { state.withLock { $0.calls.count } }
    /// The arguments, oldest first.
    var arguments: [String] { state.withLock { $0.calls } }

    /// Waits until at least `count` calls were made.
    @MainActor
    func waitForCalls(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await ShellWait.until("\(count) call(s)", sourceLocation: sourceLocation) { self.callCount >= count }
    }

    /// Answers call `index` (0-based; the newest by default).
    func succeed(_ value: Value, call index: Int? = nil) {
        resume(index) { $0.resume(returning: value) }
    }

    /// Fails call `index` (0-based; the newest by default).
    func fail(_ error: any Error = ShellTestError(), call index: Int? = nil) {
        resume(index) { $0.resume(throwing: error) }
    }

    private func resume(_ index: Int?, _ body: (CheckedContinuation<Value, any Error>) -> Void) {
        let continuation: CheckedContinuation<Value, any Error>? = state.withLock { state in
            let key = index ?? (state.calls.count - 1)
            return state.waiting.removeValue(forKey: key)
        }
        guard let continuation else {
            Issue.record("no waiting call \(index.map(String.init) ?? "newest")")
            return
        }
        body(continuation)
    }
}

/// A read that answers at once from a queue of outcomes (the last one repeats).
final class ShellQueuedReads<Value: Sendable>: Sendable {
    enum Outcome: Sendable {
        case value(Value)
        case failure(ShellTestError)
    }

    private struct State {
        var outcomes: [Outcome]
        var calls: [String] = []
    }

    private let state: Mutex<State>

    init(_ outcomes: [Outcome]) {
        state = Mutex(State(outcomes: outcomes))
    }

    convenience init(_ value: Value) {
        self.init([.value(value)])
    }

    var read: @Sendable () async throws -> Value {
        { try self.call("") }
    }

    func call(_ argument: String) throws -> Value {
        let outcome: Outcome? = state.withLock { state in
            state.calls.append(argument)
            guard let first = state.outcomes.first else { return nil }
            if state.outcomes.count > 1 { state.outcomes.removeFirst() }
            return first
        }
        switch outcome {
        case .value(let value)?: return value
        case .failure(let error)?: throw error
        case nil: throw ShellTestError("no outcome scripted")
        }
    }

    /// Replaces what the next calls answer.
    func answer(_ outcomes: [Outcome]) {
        state.withLock { $0.outcomes = outcomes }
    }

    var callCount: Int { state.withLock { $0.calls.count } }
    var arguments: [String] { state.withLock { $0.calls } }
}

/// A main-actor slot a `@Sendable` closure can read through `MainActor.assumeIsolated`.
@MainActor
final class ShellHolder<Value> {
    var value: Value?
    init() {}
}

/// An ordered log that any isolation domain can append to.
final class ShellEventLog: Sendable {
    private let storage = Mutex<[String]>([])

    init() {}

    func record(_ event: String) {
        storage.withLock { $0.append(event) }
    }

    var events: [String] { storage.withLock { $0 } }

    /// Whether `first` was recorded before `second` (both recorded).
    func order(_ first: String, before second: String) -> Bool {
        let events = events
        guard let a = events.firstIndex(of: first), let b = events.firstIndex(of: second) else { return false }
        return a < b
    }
}

/// A gate a fake step waits on until the test opens it.
final class ShellGate: Sendable {
    private struct State {
        var open = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    init() {}

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                if state.open { return true }
                state.waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state in
            state.open = true
            defer { state.waiting.removeAll() }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }

    var waiterCount: Int { state.withLock { $0.waiting.count } }
}

/// Inventory values for the Home and drop-zone tests (RN homeList.test.ts `item`, `hit`, `place`).
enum ShellFixtures {
    static func item(
        _ id: String,
        name: String? = nil,
        quantity: Int = 1,
        containerId: String = "c1",
        category: String? = nil
    ) -> ItemWithContext {
        ItemWithContext(
            item: Item(
                id: id, containerId: containerId, name: name ?? "Item \(id)", category: category,
                quantity: quantity, notes: nil, createdAt: 0, updatedAt: 0),
            photoId: nil, photoUri: nil, photoThumbUri: nil, tags: [],
            spaceId: "s1", spaceName: "Garage", spaceIcon: "🧰", spaceColor: "#5B8DEF",
            containerName: "Tool chest", containerShortCode: "CAB-J92R")
    }

    static func hit(
        _ id: String,
        _ matchKind: ItemMatchKind = .direct,
        name: String? = nil,
        quantity: Int = 1,
        containerId: String = "c1",
        category: String? = nil
    ) -> ItemSearchResult {
        ItemSearchResult(
            item: item(id, name: name, quantity: quantity, containerId: containerId, category: category),
            matchKind: matchKind)
    }

    static func place(_ id: String, _ kind: LocationSearchResult.Kind = .container) -> LocationSearchResult {
        LocationSearchResult(kind: kind, id: id, title: id, subtitle: "", spaceId: "s1", itemCount: 0)
    }

    static func results(_ items: [ItemSearchResult], _ locations: [LocationSearchResult] = [], terms: [String] = ["x"]) -> SearchResults {
        SearchResults(terms: terms, locations: locations, items: items)
    }

    static func space(_ id: String, containers: Int, items: Int) -> SpaceWithCounts {
        SpaceWithCounts(
            space: Space(id: id, name: id, icon: "🏠", color: "#5B8DEF", createdAt: 0, updatedAt: 0),
            containerCount: containers, itemCount: items)
    }

    static func container(_ id: String, spaceName: String = "Garage") -> ContainerWithSpace {
        ContainerWithSpace(
            container: Container(id: id, spaceId: "s1", name: id, visualType: .box, shortCode: "BOX-4F2A", createdAt: 0, updatedAt: 0),
            spaceName: spaceName, itemCount: 0)
    }
}
