import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryStrings
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryAppModels

// RN has no tests for ConnectionProvider. These cover every row of the 09 §4.3 transition table
// on a ManualClock, and the ping loop, retry and resume-refresh consequences 04 §9 and 09 §4.3 list.

private let otherSession = HouseholdSession(
    origin: "https://other.example", token: String(repeating: "ef", count: 32),
    deviceId: "dev-2", deviceName: "Spare", householdName: "Cabin"
)

@MainActor
private final class ConnectionFixture {
    let clock: ManualClock
    let hub: ReachabilityHub
    let server: StubServer
    let preferences: InMemoryPreferences
    let invalidations: SharedSeamsInvalidationCounter
    let announcer: HouseholdAnnouncementRecorder
    let model: ConnectionModel

    /// - Parameter pingsReport: whether the health ping's answer reaches the hub.
    init(activity: AppActivity = .active, pingsReport: Bool = false, _ handler: @escaping StubServer.Handler = { _ in .json(530, "<html>") }) {
        let clock = ManualClock()
        let hub = ReachabilityHub()
        let server = StubServer(handler)
        let preferences = InMemoryPreferences()
        let invalidations = SharedSeamsInvalidationCounter()
        let announcer = HouseholdAnnouncementRecorder()
        model = ConnectionModel(
            reachability: hub,
            client: server.householdModelClient(hub: pingsReport ? hub : nil),
            invalidator: invalidations,
            joinPreferences: HouseholdJoinPreferences(preferences: preferences),
            activity: activity,
            clock: clock,
            announce: { text in announcer.texts.append(text) }
        )
        self.clock = clock
        self.hub = hub
        self.server = server
        self.preferences = preferences
        self.invalidations = invalidations
        self.announcer = announcer
    }

    var announcements: [String] { announcer.texts }

    var state: ConnectionState { model.state }
    var invalidated: Int { invalidations.count }
    var joinedBefore: String? { preferences.values[PreferenceKey.householdJoinedBefore] }
    var pings: [RecordedRequest] { server.householdRequests(to: "/v1/health") }

    /// Takes the state to `unsure` with a pending 2.5 s timer.
    func blip() async throws {
        model.report(.offline)
        try await clock.waitForSleepers(1)
    }

    /// Takes the state through `unsure` to `offline`.
    func goOffline() async throws {
        try await blip()
        await clock.advance(by: ConnectionModel.offlineDelay)
    }

    /// Waits until the ping loop is asleep on the clock, then lets 10 s pass.
    func nextPingTick() async throws {
        try await clock.waitForSleepers(1)
        await clock.advance(by: ConnectionModel.healthPingInterval)
    }
}

@MainActor
@Suite("ConnectionModel: transitions (09 §4.3)")
struct ConnectionModelTransitionTests {
    @Test("without a session the state is local and reports are ignored")
    func localIgnoresReports() async throws {
        let fixture = ConnectionFixture()
        #expect(fixture.state == .local)
        fixture.model.report(.unauthorized)
        fixture.model.report(.offline)
        #expect(fixture.state == .local)
        #expect(fixture.clock.pendingSleeperCount == 0)
        #expect(fixture.joinedBefore == nil)
    }

    @Test("any paired state: a new session key resets to online, cancels the timer and marks joined before")
    func newSessionResets() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(householdModelSession)
        #expect(fixture.state == .online)
        #expect(fixture.joinedBefore == "true")

        try await fixture.blip()
        #expect(fixture.state == .unsure)
        fixture.preferences.removeValue(forKey: PreferenceKey.householdJoinedBefore)
        fixture.model.sessionChanged(otherSession)
        #expect(fixture.state == .online)
        #expect(fixture.clock.pendingSleeperCount == 0)
        #expect(fixture.joinedBefore == "true")

        // The same key again is not a new session.
        fixture.preferences.removeValue(forKey: PreferenceKey.householdJoinedBefore)
        fixture.model.sessionChanged(otherSession)
        #expect(fixture.joinedBefore == nil)

        fixture.model.report(.unauthorized)
        fixture.model.sessionChanged(householdModelSession)
        #expect(fixture.state == .online)

        fixture.model.sessionChanged(nil)
        #expect(fixture.state == .local)
        #expect(fixture.joinedBefore == "true")
    }

    @Test("revoked + anything: revoked, until the session changes")
    func revokedIsSticky() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(householdModelSession)
        fixture.model.report(.unauthorized)
        #expect(fixture.state == .revoked)
        fixture.model.report(.ok)
        fixture.model.report(.offline)
        fixture.model.report(.unauthorized)
        #expect(fixture.state == .revoked)
        // ok while revoked refreshes nothing; offline while revoked starts no timer.
        #expect(fixture.invalidated == 0)
        #expect(fixture.clock.pendingSleeperCount == 0)
    }

    @Test("online + offline: unsure, with a 2.5 s timer")
    func onlineOfflineIsUnsure() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(householdModelSession)
        try await fixture.blip()
        #expect(fixture.state == .unsure)
        #expect(fixture.clock.nextDeadline == ManualClock.Instant(offset: .milliseconds(2500)))
        await fixture.clock.advance(by: .milliseconds(2499))
        #expect(fixture.state == .unsure)
    }

    @Test("unsure + offline: unsure, the running timer is kept")
    func unsureOfflineIsIgnored() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(householdModelSession)
        try await fixture.blip()
        await fixture.clock.advance(by: .seconds(1))
        fixture.model.report(.offline)
        await householdSettle()
        #expect(fixture.clock.pendingSleeperCount == 1)
        await fixture.clock.advance(by: .milliseconds(1500))
        #expect(fixture.state == .offline)
    }

    @Test("unsure + the timer firing: offline, announced, once per transition")
    func timerFiresOffline() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(householdModelSession)
        try await fixture.goOffline()
        #expect(fixture.state == .offline)
        #expect(fixture.model.reconnectingAnnouncements == 1)
        #expect(fixture.announcements == [L10n.Connection.reconnecting])
        #expect(ConnectionModel.reconnectingAnnouncement == L10n.Connection.reconnecting)

        // Back online, then offline again: announced again.
        fixture.model.report(.ok)
        try await fixture.goOffline()
        #expect(fixture.model.reconnectingAnnouncements == 2)
        #expect(fixture.announcements.count == 2)
    }

    @Test("offline + offline: offline, nothing happens")
    func offlineOfflineIsIgnored() async throws {
        let fixture = ConnectionFixture(activity: .background)
        fixture.model.sessionChanged(householdModelSession)
        try await fixture.goOffline()
        fixture.model.report(.offline)
        await householdSettle()
        #expect(fixture.state == .offline)
        #expect(fixture.clock.pendingSleeperCount == 0)
        #expect(fixture.announcements.count == 1)
    }

    @Test("unsure + ok: online, the timer cancelled, lists refreshed (the first recovery always is)")
    func unsureOkRecovers() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(householdModelSession)
        try await fixture.blip()
        fixture.model.report(.ok)
        #expect(fixture.state == .online)
        #expect(fixture.invalidated == 1)
        #expect(fixture.clock.pendingSleeperCount == 0)
        await fixture.clock.advance(by: .seconds(3))
        #expect(fixture.state == .online)
        #expect(fixture.announcements.isEmpty)
    }

    @Test("offline + ok: online and lists refreshed")
    func offlineOkRecovers() async throws {
        let fixture = ConnectionFixture(activity: .background)
        fixture.model.sessionChanged(householdModelSession)
        try await fixture.goOffline()
        fixture.model.report(.ok)
        #expect(fixture.state == .online)
        #expect(fixture.invalidated == 1)
    }

    @Test("recovery refreshes at most every 5 s, counted per session")
    func recoveryThrottle() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(householdModelSession)
        try await fixture.blip()
        fixture.model.report(.ok)
        #expect(fixture.invalidated == 1)

        await fixture.clock.advance(by: .seconds(4))
        try await fixture.blip()
        fixture.model.report(.ok)
        #expect(fixture.state == .online)
        #expect(fixture.invalidated == 1)

        await fixture.clock.advance(by: .seconds(1))
        try await fixture.blip()
        fixture.model.report(.ok)
        #expect(fixture.invalidated == 2)

        // A new session forgets the last recovery: its first recovery refreshes at once, although
        // the last one was moments ago. (The session change itself, 5 s after the session load
        // armed the resume clock, is also a resume refresh.)
        fixture.model.sessionChanged(otherSession)
        #expect(fixture.invalidated == 3)
        try await fixture.blip()
        fixture.model.report(.ok)
        #expect(fixture.invalidated == 4)
    }

    @Test("online + ok: online, nothing refreshed")
    func onlineOkIsQuiet() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(householdModelSession)
        fixture.model.report(.ok)
        #expect(fixture.state == .online)
        #expect(fixture.invalidated == 0)
    }

    @Test("not revoked + unauthorized: revoked, the timer cancelled")
    func unauthorizedRevokes() async throws {
        for setup in ["online", "unsure", "offline"] {
            let fixture = ConnectionFixture(activity: .background)
            fixture.model.sessionChanged(householdModelSession)
            if setup == "unsure" { try await fixture.blip() }
            if setup == "offline" { try await fixture.goOffline() }
            fixture.model.report(.unauthorized)
            #expect(fixture.state == .revoked, "from \(setup)")
            #expect(fixture.clock.pendingSleeperCount == 0, "from \(setup)")
            await fixture.clock.advance(by: .seconds(30))
            #expect(fixture.state == .revoked, "from \(setup)")
        }
    }

    @Test("reports reach the model through the hub; a new session listens afresh")
    func hubReports() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(householdModelSession)
        fixture.hub.report(.unauthorized)
        #expect(await householdWaitUntil { fixture.state == .revoked })
        fixture.model.sessionChanged(otherSession)
        #expect(fixture.state == .online)
        fixture.hub.report(.offline)
        #expect(await householdWaitUntil { fixture.state == .unsure })
        fixture.model.sessionChanged(nil)
        fixture.hub.report(.unauthorized)
        await householdSettle()
        #expect(fixture.state == .local)
    }

    @Test("follow takes the household's session now and on every change")
    func followsTheHousehold() async throws {
        let household = try HouseholdModelFixture(keychain: InMemoryKeychain([KeychainKey.householdSession: householdModelSession.jsonString]))
        let fixture = ConnectionFixture()
        fixture.model.follow(household.household)
        #expect(fixture.state == .local)
        await household.household.load()
        #expect(fixture.state == .online)
        household.household.disconnect(revokeDevice: false)
        #expect(fixture.state == .local)
    }
}

@MainActor
@Suite("ConnectionModel: health ping, retry and resume refresh")
struct ConnectionModelEffectsTests {
    @Test("while offline and active, the health endpoint is asked every 10 s, without a token, at the session's origin")
    func pingsEveryTenSeconds() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(otherSession)
        try await fixture.goOffline()
        #expect(fixture.pings.isEmpty)

        try await fixture.nextPingTick()
        #expect(await householdWaitUntil { fixture.pings.count == 1 })
        let ping = try #require(fixture.pings.first)
        #expect(ping.line == "GET https://other.example/v1/health")
        #expect(ping.header("authorization") == nil)

        try await fixture.nextPingTick()
        #expect(await householdWaitUntil { fixture.pings.count == 2 })
    }

    @Test("no pings while unsure, online, revoked or in the background; they resume 10 s after becoming active")
    func pingsOnlyWhileOfflineAndActive() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(householdModelSession)
        try await fixture.blip()
        #expect(fixture.clock.pendingSleeperCount == 1)  // the offline timer, no ping loop
        await fixture.clock.advance(by: ConnectionModel.offlineDelay)
        try await fixture.clock.waitForSleepers(1)

        fixture.model.activityChanged(.background)
        await householdSettle()
        #expect(fixture.clock.pendingSleeperCount == 0)
        await fixture.clock.advance(by: .seconds(30))
        #expect(fixture.pings.isEmpty)

        fixture.model.activityChanged(.active)
        try await fixture.clock.waitForSleepers(1)
        await fixture.clock.advance(by: .seconds(9))
        #expect(fixture.pings.isEmpty)
        await fixture.clock.advance(by: .seconds(1))
        #expect(await householdWaitUntil { fixture.pings.count == 1 })

        fixture.model.report(.ok)
        await householdSettle()
        #expect(fixture.clock.pendingSleeperCount == 0)
        await fixture.clock.advance(by: .seconds(30))
        #expect(fixture.pings.count == 1)
    }

    @Test("a ping's own answer drives the state: Cloudflare's 530 keeps it offline, an answer recovers")
    func pingsReport() async throws {
        let answers = HouseholdPingAnswers()
        let fixture = ConnectionFixture(pingsReport: true) { _ in answers.next() }
        fixture.model.sessionChanged(householdModelSession)
        try await fixture.goOffline()

        try await fixture.nextPingTick()
        #expect(await householdWaitUntil { fixture.pings.count == 1 })
        await householdSettle()
        #expect(fixture.state == .offline)

        answers.recover()
        try await fixture.nextPingTick()
        #expect(await householdWaitUntil { fixture.state == .online })
        #expect(fixture.invalidated == 1)
    }

    @Test("retry asks the home server at once and re-reads every list")
    func retry() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(householdModelSession)
        fixture.model.retry()
        #expect(fixture.invalidated == 1)
        #expect(await householdWaitUntil { fixture.pings.count == 1 })
        #expect(fixture.pings.first?.line == "GET https://inventory.wystudio.be/v1/health")

        let unpaired = ConnectionFixture()
        unpaired.model.retry()
        #expect(unpaired.invalidated == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(unpaired.pings.isEmpty)
    }

    @Test("the first evaluation while paired and active only starts the clock; later ones refresh at most every 5 s")
    func resumeRefresh() async throws {
        let fixture = ConnectionFixture()
        // The session load resolving while active is the first evaluation.
        fixture.model.sessionChanged(householdModelSession)
        #expect(fixture.invalidated == 0)

        fixture.model.activityChanged(.inactive)
        fixture.model.activityChanged(.active)
        #expect(fixture.invalidated == 0)  // less than 5 s since

        await fixture.clock.advance(by: .seconds(5))
        fixture.model.activityChanged(.inactive)
        fixture.model.activityChanged(.active)  // Control Center closing counts
        #expect(fixture.invalidated == 1)

        await fixture.clock.advance(by: .seconds(6))
        fixture.model.activityChanged(.background)
        #expect(fixture.invalidated == 1)
        fixture.model.activityChanged(.active)
        #expect(fixture.invalidated == 2)

        // Repeating the current activity is not a transition.
        await fixture.clock.advance(by: .seconds(6))
        fixture.model.activityChanged(.active)
        #expect(fixture.invalidated == 2)
    }

    @Test("a session change while active counts as a resume; the clock lives as long as the model")
    func resumeOnSessionChange() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(householdModelSession)
        #expect(fixture.invalidated == 0)

        // Leaving and rejoining within 5 s refreshes nothing.
        fixture.model.sessionChanged(nil)
        fixture.model.sessionChanged(otherSession)
        #expect(fixture.invalidated == 0)

        // More than 5 s after the last evaluation, a rejoin refreshes: lastResume was not reset.
        await fixture.clock.advance(by: .seconds(6))
        fixture.model.sessionChanged(nil)
        #expect(fixture.invalidated == 0)  // no session, no resume
        fixture.model.sessionChanged(householdModelSession)
        #expect(fixture.invalidated == 1)
    }

    @Test("a phone that started unpaired: joining is the first evaluation and refreshes nothing")
    func pairingLaterArmsOnly() async throws {
        let fixture = ConnectionFixture()
        fixture.model.sessionChanged(nil)
        await fixture.clock.advance(by: .seconds(60))
        fixture.model.activityChanged(.background)
        fixture.model.activityChanged(.active)
        #expect(fixture.invalidated == 0)  // local phones never get a resume refresh
        fixture.model.sessionChanged(householdModelSession)
        #expect(fixture.invalidated == 0)
    }

    @Test("in the background nothing is evaluated; the session load then arms on the first activation")
    func backgroundLaunch() async throws {
        let fixture = ConnectionFixture(activity: .background)
        fixture.model.sessionChanged(householdModelSession)
        fixture.model.activityChanged(.active)
        #expect(fixture.invalidated == 0)
        await fixture.clock.advance(by: .seconds(5))
        fixture.model.activityChanged(.background)
        fixture.model.activityChanged(.active)
        #expect(fixture.invalidated == 1)
    }
}

@MainActor
@Suite("ConnectionModel: timing (04 §3.1, §9.1)")
struct ConnectionModelTimingTests {
    @Test("the offline delay, ping interval, health deadline, refresh throttle and leave deadline are RN's")
    func constants() {
        #expect(ConnectionModel.offlineDelay == .milliseconds(2500))
        #expect(ConnectionModel.healthPingInterval == .seconds(10))
        #expect(ConnectionModel.healthTimeout == .seconds(5))
        #expect(ConnectionModel.resumeRefreshInterval == .seconds(5))
        #expect(HouseholdModel.leaveRevokeTimeout == .seconds(5))
    }

    @Test("a health ping gets 5 s; one that gets no answer by then reports offline")
    func pingDeadline() async throws {
        let clock = ManualClock()
        let hub = ReachabilityHub()
        let server = StubServer { _ in .json(200, #"{"ok":true,"contractVersion":1}"#, delay: .seconds(60)) }
        let client = HouseholdClient(
            origin: "https://inventory.wystudio.be", token: nil, transport: HouseholdModelStubTransport(server),
            reachability: hub, clock: clock, telemetry: NetworkTelemetry(event: { _, _ in }, error: { _, _ in })
        )
        let model = ConnectionModel(
            reachability: hub, client: client, invalidator: SharedSeamsInvalidationCounter(),
            joinPreferences: HouseholdJoinPreferences(preferences: InMemoryPreferences()), clock: clock
        )
        model.sessionChanged(householdModelSession)
        model.retry()
        try await clock.waitForSleepers(1)
        #expect(clock.nextDeadline == ManualClock.Instant(offset: .seconds(5)))
        await clock.advance(by: .milliseconds(4999))
        await householdSettle()
        #expect(model.state == .online)
        await clock.advance(by: .milliseconds(1))
        #expect(await householdWaitUntil { model.state == .unsure })
    }
}

/// What the model asked VoiceOver to say.
@MainActor
private final class HouseholdAnnouncementRecorder {
    var texts: [String] = []
}

/// Health answers: Cloudflare's "origin down" until the home server comes back.
private final class HouseholdPingAnswers: Sendable {
    private let recovered = Mutex(false)

    func recover() {
        recovered.withLock { $0 = true }
    }

    func next() -> StubReply {
        recovered.withLock { $0 }
            ? .json(200, #"{"ok":true,"contractVersion":1}"#)
            : .text(530, "<html>origin down</html>", contentType: "text/html")
    }
}
