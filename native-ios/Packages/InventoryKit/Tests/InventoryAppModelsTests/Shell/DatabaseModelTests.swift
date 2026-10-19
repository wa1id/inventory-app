import InventoryCore
import InventoryStorage
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// 09 §4.1 / §14.2 `DatabaseModelTests`: open success and failure, retry closes and reopens,
/// invalidate increments.
@Suite("DatabaseModel (src/providers/DatabaseProvider.tsx)")
@MainActor
struct DatabaseModelTests {
    /// A migrated in-memory database, as `openLive` would return.
    private nonisolated static func migratedStore() throws -> DatabaseStore {
        let store = try DatabaseStore.inMemory()
        try store.migrate()
        return store
    }

    @Test("opens and migrates, then reports database_ready with how long it took")
    func openSuccess() async throws {
        let clock = ManualClock()
        let telemetry = RecordingTelemetry()
        let model = DatabaseModel(
            open: {
                try await clock.sleep(for: .milliseconds(250))
                return try Self.migratedStore()
            },
            clock: clock, telemetry: TelemetryReporter(sink: telemetry))
        #expect(model.status == .loading)
        #expect(model.repositories == nil)

        let opening = Task { await model.open() }
        try await clock.waitForSleepers()
        await clock.advance(by: .milliseconds(250))
        await opening.value

        #expect(model.status == .ready)
        let store = try #require(model.store)
        #expect(try await store.schemaVersion() == 7)
        #expect(model.repositories != nil)
        #expect(telemetry.entries == [RecordingTelemetry.Entry(level: "event", name: "database_ready", payload: ["durationMs": .int(250)])])
    }

    @Test("a failure shows the failure state and reports database_open_failed as an event")
    func openFailure() async throws {
        let clock = ManualClock()
        let telemetry = RecordingTelemetry()
        let model = DatabaseModel(
            open: {
                try await clock.sleep(for: .milliseconds(40))
                throw ShellTestError("disk I/O error")
            },
            clock: clock, telemetry: TelemetryReporter(sink: telemetry))
        let opening = Task { await model.open() }
        try await clock.waitForSleepers()
        await clock.advance(by: .milliseconds(40))
        await opening.value

        #expect(model.status == .failed)
        #expect(model.repositories == nil)
        #expect(model.store == nil)
        #expect(telemetry.entries == [RecordingTelemetry.Entry(level: "event", name: "database_open_failed", payload: ["durationMs": .int(40)])])
    }

    @Test("Try again shows loading, then opens again")
    func retryAfterFailure() async throws {
        let attempts = ShellQueuedReads<Bool>([.failure(ShellTestError()), .value(true)])
        let gate = ShellGate()
        let model = DatabaseModel(open: {
            if try attempts.call("open") == false { throw ShellTestError() }
            await gate.wait()
            return try Self.migratedStore()
        }, telemetry: TelemetryReporter(sink: RecordingTelemetry()))
        await model.open()
        #expect(model.status == .failed)

        let retrying = Task { await model.retry() }
        await ShellWait.until("the retry to start") { gate.waiterCount == 1 }
        #expect(model.status == .loading)
        gate.open()
        await retrying.value
        #expect(model.status == .ready)
        #expect(attempts.callCount == 2)
    }

    @Test("an open database is never reopened: Try again and open leave the live connection alone")
    func neverReopened() async throws {
        let first = try Self.migratedStore()
        let calls = ShellQueuedReads<DatabaseStore>([.value(first), .failure(ShellTestError("second connection"))])
        let model = DatabaseModel(open: { try calls.call("open") }, telemetry: TelemetryReporter(sink: RecordingTelemetry()))
        await model.open()
        #expect(model.store === first)

        await model.retry()
        await model.open()
        #expect(calls.callCount == 1)
        #expect(model.store === first)
        #expect(try await first.schemaVersion() == 7)
    }

    @Test("a second Try again while the database is opening waits for that open: one connection")
    func doubleTapJoins() async throws {
        let attempts = ShellQueuedReads<Bool>([.failure(ShellTestError()), .value(true)])
        let gate = ShellGate()
        let telemetry = RecordingTelemetry()
        let model = DatabaseModel(open: {
            if try attempts.call("open") == false { throw ShellTestError() }
            await gate.wait()
            return try Self.migratedStore()
        }, telemetry: TelemetryReporter(sink: telemetry))
        await model.open()
        #expect(model.status == .failed)

        let firstTap = Task { await model.retry() }
        await ShellWait.until("the retry to open") { gate.waiterCount == 1 }
        let secondTap = Task { await model.retry() }
        let boot = Task { await model.open() }
        await ShellWait.settle()
        #expect(attempts.callCount == 2)
        #expect(gate.waiterCount == 1)

        gate.open()
        await firstTap.value
        await secondTap.value
        await boot.value
        #expect(model.status == .ready)
        #expect(attempts.callCount == 2)
        #expect(telemetry.names == ["database_open_failed", "database_ready"])
    }

    @Test("cancelling the caller does not fail the open: the migration runs to the end")
    func callerCancellationIgnored() async throws {
        let gate = ShellGate()
        let telemetry = RecordingTelemetry()
        let model = DatabaseModel(open: {
            await gate.wait()
            // Like GRDB's async access, a cancellation-aware open throws when its task is cancelled.
            try Task.checkCancellation()
            return try Self.migratedStore()
        }, telemetry: TelemetryReporter(sink: telemetry))
        let caller = Task { await model.open() }
        await ShellWait.until("the open to wait") { gate.waiterCount == 1 }
        caller.cancel()
        gate.open()
        await caller.value
        #expect(model.status == .ready)
        #expect(telemetry.names == ["database_ready"])
    }

    @Test("state observers hear every change: ready, and loading then ready again after Try again")
    func stateObservers() async throws {
        let attempts = ShellQueuedReads<Bool>([.failure(ShellTestError()), .value(true)])
        let model = DatabaseModel(open: {
            if try attempts.call("open") == false { throw ShellTestError() }
            return try Self.migratedStore()
        }, telemetry: TelemetryReporter(sink: RecordingTelemetry()))
        let log = ShellEventLog()
        let observation = model.addStateObserver { state in
            switch state {
            case .loading: log.record("loading")
            case .ready(let repositories): log.record(repositories.store === model.store ? "ready" : "ready (stale)")
            case .failed: log.record("failed")
            }
        }
        let other = model.addStateObserver { _ in log.record("second observer") }

        await model.open()
        #expect(log.events == ["failed", "second observer"])
        model.removeStateObserver(other)
        await model.retry()
        #expect(log.events == ["failed", "second observer", "loading", "ready"])
        model.removeStateObserver(observation)
        model.invalidate()
        #expect(log.events.count == 4)
    }

    @Test("invalidate bumps the revision from 0, one at a time, through the shared seam")
    func invalidate() {
        let model = DatabaseModel(open: { try Self.migratedStore() })
        #expect(model.revision == 0)
        model.invalidate()
        let writer: any InventoryInvalidating = model
        writer.invalidate()
        #expect(model.revision == 2)
    }
}
