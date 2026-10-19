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

    @Test("retry closes the previous connection before opening a new one")
    func retryClosesPrevious() async throws {
        let first = try Self.migratedStore()
        let second = try Self.migratedStore()
        let stores = ShellQueuedReads<Int>([.value(0), .value(1)])
        let model = DatabaseModel(open: {
            try stores.call("open") == 0 ? first : second
        }, telemetry: TelemetryReporter(sink: RecordingTelemetry()))
        await model.open()
        #expect(model.store === first)

        await model.retry()
        #expect(model.store === second)
        #expect(throws: (any Error).self) { try first.schemaVersion() }
        #expect(try await second.schemaVersion() == 7)
    }

    @Test("an attempt a retry superseded is dropped, and its connection closed")
    func staleAttemptDropped() async throws {
        let slow = try Self.migratedStore()
        let fast = try Self.migratedStore()
        let gate = ShellGate()
        let calls = ShellQueuedReads<Int>([.value(0), .value(1)])
        let telemetry = RecordingTelemetry()
        let model = DatabaseModel(open: {
            if try calls.call("open") == 0 {
                await gate.wait()
                return slow
            }
            return fast
        }, telemetry: TelemetryReporter(sink: telemetry))

        let firstOpen = Task { await model.open() }
        await ShellWait.until("the first open to wait") { gate.waiterCount == 1 }
        await model.retry()
        #expect(model.store === fast)

        gate.open()
        await firstOpen.value
        #expect(model.store === fast)
        #expect(throws: (any Error).self) { try slow.schemaVersion() }
        #expect(telemetry.names == ["database_ready"])
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
