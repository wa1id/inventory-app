import Foundation
import InventoryCore
import InventoryStorage
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// 09 §14.2 `BootGateTests`: precedence (the database error beats loading; all three are
/// needed; fonts and the backup account never gate), and the boot order of 09 §3.2.
@Suite("BootGate (app/_layout.tsx RootNavigator)")
struct BootGateTests {
    typealias Database = DatabaseModel.Status
    typealias Onboarding = OnboardingModel.Status

    @Test("a database error shows the failure screen, even while everything else loads", arguments: [
        (Onboarding.loading, false), (.loading, true), (.pending, false), (.completed, false), (.completed, true),
    ])
    func databaseErrorFirst(onboarding: Onboarding, householdReady: Bool) {
        #expect(BootGate.phase(database: .failed, onboarding: onboarding, householdReady: householdReady) == .failed)
    }

    @Test("any of the three still loading shows the boot view", arguments: [
        (Database.loading, Onboarding.completed, true),
        (.ready, .loading, true),
        (.ready, .completed, false),
        (.ready, .pending, false),
        (.loading, .loading, false),
    ])
    func allThreeNeeded(database: Database, onboarding: Onboarding, householdReady: Bool) {
        #expect(BootGate.phase(database: database, onboarding: onboarding, householdReady: householdReady) == .booting)
    }

    @Test("once all three are known, the onboarding status alone picks the root")
    func onboardingOrMain() {
        #expect(BootGate.phase(database: .ready, onboarding: .completed, householdReady: true) == .main)
        #expect(BootGate.phase(database: .ready, onboarding: .pending, householdReady: true) == .onboarding)
    }
}

/// The boot sequence of 09 §3.2 / 02 §8 with fake steps.
@Suite("AppBoot (09 §3.2)")
@MainActor
struct AppBootTests {
    /// Fake steps that log what ran, in order, and can be held.
    @MainActor
    private final class Harness {
        let log = ShellEventLog()
        let protectedData = ShellGate()
        let session = ShellGate()
        let syncAccount = ShellGate()
        let database: DatabaseModel
        let onboarding: OnboardingModel
        let boot: AppBoot

        init(
            onboardingStored: String? = "true",
            databaseFails: Bool = false,
            holdSession: Bool = false,
            holdSyncAccount: Bool = false,
            withSync: Bool = true
        ) {
            let log = log
            let preferences = InMemoryPreferences()
            database = DatabaseModel(open: {
                log.record("database.open")
                if databaseFails { throw ShellTestError("migrate") }
                let store = try DatabaseStore.inMemory()
                try await store.migrate()
                return store
            }, telemetry: TelemetryReporter(sink: RecordingTelemetry()))
            onboarding = OnboardingModel(storage: OnboardingModel.Storage(
                read: {
                    log.record("onboarding.read")
                    return OnboardingPreference(preferences: preferences).isCompleted
                },
                write: { _ in }))
            let protectedData = protectedData
            let session = session
            let syncAccount = syncAccount
            var syncStep: (@MainActor @Sendable () async -> Void)?
            if withSync {
                syncStep = {
                    log.record("sync.load")
                    if holdSyncAccount { await syncAccount.wait() }
                    log.record("sync.loaded")
                }
            }
            boot = AppBoot(database: database, onboarding: onboarding, steps: AppBoot.Steps(
                waitForProtectedData: {
                    log.record("protectedData.wait")
                    await protectedData.wait()
                    log.record("protectedData.available")
                },
                importLegacyPreferences: {
                    log.record("legacy.import")
                    // What the import copies is what the onboarding read must see.
                    if let onboardingStored { preferences.setString(onboardingStored, forKey: PreferenceKey.onboardingCompleted) }
                },
                loadHouseholdSession: {
                    log.record("household.load")
                    if holdSession { await session.wait() }
                    log.record("household.loaded")
                },
                loadSyncAccount: syncStep,
                purgeTemporaryCaches: { log.record("caches.purge") }))
        }

        func releaseAll() {
            protectedData.open()
            session.open()
            syncAccount.open()
        }
    }

    @Test("creating the boot does nothing; the gate shows the boot view")
    func noWorkAtInit() async {
        let harness = Harness()
        await ShellWait.settle()
        #expect(harness.log.events.isEmpty)
        #expect(harness.boot.phase == .booting)
        #expect(harness.boot.progress == .notStarted)
    }

    @Test("nothing reads preferences, the keychain or the database before protected data is available")
    func waitsForProtectedData() async {
        let harness = Harness()
        let running = Task { await harness.boot.run() }
        await ShellWait.until("the wait") { harness.protectedData.waiterCount == 1 }
        await ShellWait.settle()
        #expect(harness.log.events == ["protectedData.wait"])
        #expect(harness.boot.progress == .waitingForProtectedData)
        #expect(harness.boot.phase == .booting)

        harness.protectedData.open()
        await running.value
        #expect(harness.boot.phase == .main)
        await harness.boot.syncAccountTask?.value
    }

    @Test("the legacy import runs before any preference read, and both before the keychain and database")
    func order() async {
        let harness = Harness()
        harness.protectedData.open()
        await harness.boot.run()
        await harness.boot.syncAccountTask?.value
        await harness.boot.cachePurgeTask?.value
        let log = harness.log
        #expect(log.order("protectedData.available", before: "legacy.import"))
        #expect(log.order("legacy.import", before: "onboarding.read"))
        #expect(log.order("onboarding.read", before: "database.open"))
        #expect(log.order("onboarding.read", before: "household.load"))
        #expect(log.order("legacy.import", before: "sync.load"))
        #expect(log.order("household.loaded", before: "caches.purge"))
        #expect(log.events.filter { $0 == "caches.purge" }.count == 1)
        // The flag the import copied was read: an existing user does not see onboarding again.
        #expect(harness.onboarding.status == .completed)
        #expect(harness.boot.phase == .main)
        #expect(harness.boot.progress == .finished)
    }

    @Test("a pending onboarding flag shows onboarding once the gate passes")
    func onboardingPending() async {
        let harness = Harness(onboardingStored: nil)
        harness.protectedData.open()
        await harness.boot.run()
        #expect(harness.boot.phase == .onboarding)
        await harness.boot.syncAccountTask?.value
    }

    @Test("the gate waits for the household session, paired or not")
    func waitsForSession() async {
        let harness = Harness(holdSession: true)
        harness.protectedData.open()
        let running = Task { await harness.boot.run() }
        await ShellWait.until("the database") { harness.database.status == .ready }
        await ShellWait.until("the session load") { harness.session.waiterCount == 1 }
        #expect(!harness.boot.householdReady)
        #expect(harness.boot.phase == .booting)
        harness.session.open()
        await running.value
        #expect(harness.boot.householdReady)
        #expect(harness.boot.phase == .main)
        await harness.boot.syncAccountTask?.value
    }

    @Test("a database failure shows first, while the session is still loading")
    func databaseFailureFirst() async {
        let harness = Harness(databaseFails: true, holdSession: true)
        harness.protectedData.open()
        let running = Task { await harness.boot.run() }
        await ShellWait.until("the failure") { harness.database.status == .failed }
        #expect(!harness.boot.householdReady)
        #expect(harness.boot.phase == .failed)
        harness.releaseAll()
        await running.value
        #expect(harness.boot.phase == .failed)
        await harness.boot.syncAccountTask?.value
    }

    @Test("the backup account never gates")
    func syncAccountNeverGates() async {
        let harness = Harness(holdSyncAccount: true)
        harness.protectedData.open()
        await harness.boot.run()
        #expect(harness.boot.phase == .main)
        #expect(harness.log.events.contains("sync.load"))
        #expect(!harness.log.events.contains("sync.loaded"))
        harness.syncAccount.open()
        await harness.boot.syncAccountTask?.value
        #expect(harness.log.events.contains("sync.loaded"))
    }

    @Test("without sync configured the account is never loaded")
    func noSyncConfigured() async {
        let harness = Harness(withSync: false)
        harness.protectedData.open()
        await harness.boot.run()
        #expect(harness.boot.syncAccountTask == nil)
        #expect(!harness.log.events.contains("sync.load"))
    }

    @Test("boot runs once per process")
    func runsOnce() async {
        let harness = Harness()
        harness.protectedData.open()
        await harness.boot.run()
        await harness.boot.run()
        await harness.boot.cachePurgeTask?.value
        await harness.boot.syncAccountTask?.value
        #expect(harness.log.events.filter { $0 == "legacy.import" }.count == 1)
        #expect(harness.log.events.filter { $0 == "database.open" }.count == 1)
    }

    @Test("cancelling the caller neither fails the database open nor cuts boot short")
    func callerCancellation() async {
        let gate = ShellGate()
        let database = DatabaseModel(open: {
            await gate.wait()
            // Like GRDB's async access, a cancellation-aware open throws when its task is cancelled.
            try Task.checkCancellation()
            let store = try DatabaseStore.inMemory()
            try await store.migrate()
            return store
        }, telemetry: TelemetryReporter(sink: RecordingTelemetry()))
        let onboarding = OnboardingModel(storage: OnboardingModel.Storage(read: { true }, write: { _ in }))
        let log = ShellEventLog()
        let unlocked = ShellHolder<Bool>()
        let boot = AppBoot(database: database, onboarding: onboarding, steps: AppBoot.Steps(
            waitForProtectedData: {
                // Like ProtectedData.waitUntilAvailable, whose notification loop ends when its
                // task is cancelled.
                while unlocked.value != true, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(1))
                }
            },
            importLegacyPreferences: { log.record(unlocked.value == true ? "import" : "import while locked") },
            loadHouseholdSession: { log.record("household.loaded") },
            loadSyncAccount: nil,
            purgeTemporaryCaches: {}))

        // The caller goes away while the device is still locked: boot keeps waiting for the unlock.
        let caller = Task { await boot.run() }
        await ShellWait.until("the wait") { boot.progress == .waitingForProtectedData }
        caller.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(log.events.isEmpty)
        #expect(boot.progress == .waitingForProtectedData)

        // ... and goes away again while the database migrates: the open still completes.
        let second = Task { await boot.run() }
        unlocked.value = true
        await ShellWait.until("the open to wait") { gate.waiterCount == 1 }
        second.cancel()
        gate.open()
        await second.value
        await caller.value
        #expect(log.events == ["import", "household.loaded"])
        #expect(database.status == .ready)
        #expect(boot.householdReady)
        #expect(boot.phase == .main)
        #expect(boot.progress == .finished)

        // A later call waits for the same boot; nothing runs twice.
        await boot.run()
        #expect(log.events == ["import", "household.loaded"])
    }

    @Test("with the real import: an RN onboarding flag in the AsyncStorage manifest opens the main shell")
    func realLegacyImportBeforeOnboardingRead() async throws {
        let container = try TemporaryDirectory()
        let suite = try TemporaryDefaults()
        try container.write(
            Data(#"{"onboarding.completed.v1":"true"}"#.utf8),
            to: "Library/Application Support/com.wystudio.inventory/RCTAsyncLocalStorage_V1/manifest.json")
        let reader = LegacyAsyncStorageReader(
            applicationSupport: container.applicationSupport, documents: container.documents,
            bundleIdentifier: "com.wystudio.inventory")
        let defaults = suite.defaults
        let database = DatabaseModel(open: {
            let store = try DatabaseStore.inMemory()
            try await store.migrate()
            return store
        }, telemetry: TelemetryReporter(sink: RecordingTelemetry()))
        let onboarding = OnboardingModel(preferences: defaults)
        let boot = AppBoot(database: database, onboarding: onboarding, steps: AppBoot.Steps(
            waitForProtectedData: {},
            importLegacyPreferences: {
                LegacyImport(defaults: defaults, reader: reader, isProtectedDataAvailable: { true }).runIfNeeded()
            },
            loadHouseholdSession: {},
            loadSyncAccount: nil,
            purgeTemporaryCaches: {}))
        await boot.run()
        #expect(onboarding.status == .completed)
        #expect(boot.phase == .main)
        #expect(defaults.integer(forKey: LegacyImport.markerKey) == 1)
    }
}
