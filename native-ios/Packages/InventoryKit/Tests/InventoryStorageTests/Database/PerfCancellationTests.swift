import Foundation
import GRDB
import Synchronization
import Testing
@testable import InventoryStorage

/// A search superseded by the next keystroke must not keep the one database connection busy
/// (docs/PERFORMANCE.md): `SearchModel` and `InventoryQuery` cancel the task of a read they no
/// longer want, and the store's async reads must then stop, so the next read starts at once
/// instead of queueing behind stale ones.
@Suite("perf: cancelled reads give the database back")
struct PerfCancellationTests {
    /// A statement that runs until it is interrupted.
    private static let endless = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT COUNT(*) FROM n"

    @Test("cancelling a read stops its running statement, and the next read starts at once")
    func cancelStopsTheStatement() async throws {
        let store = try DatabaseStore.temporary()
        try await store.migrate()
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let stale = Task {
            try await store.queue.read { db in
                startedSignal.yield()
                return try Int.fetchOne(db, sql: Self.endless)
            }
        }
        var iterator = started.makeAsyncIterator()
        await iterator.next()
        stale.cancel()
        let outcome = try #require(await Self.result(of: stale))
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(try await store.queue.read { db in try Int.fetchOne(db, sql: "SELECT 1") } == 1)
    }

    @Test("a read cancelled while it waits for the connection never runs")
    func cancelledWhileWaiting() async throws {
        let store = try DatabaseStore.temporary()
        try await store.migrate()
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let busy = Task {
            try await store.queue.read { db in
                startedSignal.yield()
                return try Int.fetchOne(db, sql: Self.endless)
            }
        }
        var iterator = started.makeAsyncIterator()
        await iterator.next()

        let ran = Mutex(false)
        let waiting = Task {
            try await store.queue.read { _ in ran.withLock { $0 = true } }
        }
        waiting.cancel()
        busy.cancel()
        let waitingOutcome = try #require(await Self.result(of: waiting))
        #expect(throws: CancellationError.self) { try waitingOutcome.get() }
        let busyOutcome = try #require(await Self.result(of: busy))
        #expect(throws: CancellationError.self) { try busyOutcome.get() }
        #expect(!ran.withLock { $0 })
    }

    /// The task's result, or nil with an issue when it is still running after a minute of real
    /// time (a regression that stopped interrupting would otherwise hang the run).
    private static func result<T: Sendable>(of task: Task<T, any Error>, sourceLocation: SourceLocation = #_sourceLocation) async -> Result<T, any Error>? {
        let outcome: Result<T, any Error>? = await withCheckedContinuation { continuation in
            let once = PerfCancellationOnce(continuation)
            let watchdog = Task {
                // Cancelled once the task has answered: then it must not answer for it.
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                once.resume(nil)
            }
            Task {
                let result = await task.result
                once.resume(result)
                watchdog.cancel()
            }
        }
        if outcome == nil { Issue.record("still running after a minute", sourceLocation: sourceLocation) }
        return outcome
    }
}

/// Resumes a continuation once; later calls do nothing.
private final class PerfCancellationOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: Value) {
        continuation.withLock { stored in
            stored?.resume(returning: value)
            stored = nil
        }
    }
}
