import Foundation
import Observation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryStrings

/// What the phone knows about its connection to the home server (RN `ConnectionState`,
/// src/providers/ConnectionProvider.tsx:20-27).
public enum ConnectionState: String, Sendable, Hashable, CaseIterable {
    /// Not part of a household; nothing to reach.
    case local
    /// The home server answered the last request.
    case online
    /// A request failed less than 2.5 s ago; probably a blip. Only the Household status card
    /// tells it from `online` (04 Q10).
    case unsure
    /// Requests have been failing for 2.5 s: the connection banner shows.
    case offline
    /// The server no longer accepts this phone (removed on another phone). Sticky until the
    /// session changes; the removed-phone layer covers the app.
    case revoked
}

/// The connection state machine (RN `ConnectionProvider`; 04 §9, 09 §4.3).
///
/// Driven by the requests the app makes anyway: every household request reports a
/// ``Reachability`` through the ``ReachabilityHub``. Calm on purpose: a failure first makes the
/// state `unsure`, and only after 2.5 s without an answer does it become `offline`, so brief
/// blips never show a banner. While offline and active it asks the unauthenticated health
/// endpoint every 10 s. The first answer after any failure re-reads every list (at most every
/// 5 s). A 401 means this phone was removed elsewhere; that sticks until the session changes.
/// Coming back to the app re-reads lists, so changes made on another phone show up (#47).
///
/// Inputs: the household session (``sessionChanged(_:)``, or ``follow(_:)``), the app's
/// activity (``activityChanged(_:)``, every scene-phase change), the hub's reports, and
/// ``retry()`` from the connection banner. Timers run on the injected clock.
///
/// Transitions (`set(next)` is ignored while revoked or when nothing changes):
///
/// | State | Input | Next | Also |
/// | --- | --- | --- | --- |
/// | any | session key changes | `online` (`local` without a session) | timers cancelled, `lastRecovery` forgotten, `markJoinedBefore()` for a new key |
/// | `revoked` | anything | `revoked` | |
/// | `online` | `offline` | `unsure` | 2.5 s timer starts |
/// | `unsure` | timer fires | `offline` | ``reconnectingAnnouncements`` bumped and the reconnecting copy announced; pings start when active |
/// | `unsure`/`offline`/`revoked` | `offline` | unchanged | |
/// | `unsure`/`offline` | `ok` | `online` | timer cancelled; lists invalidated if 5 s passed since the last recovery (always the first time) |
/// | `online`/`revoked` | `ok` | unchanged | timer cancelled; nothing invalidated |
/// | not `revoked` | `unauthorized` | `revoked` | timer cancelled |
@MainActor
@Observable
public final class ConnectionModel {
    /// While offline, how often the home server is asked whether it is back (RN `HEALTH_PING_MS`).
    public nonisolated static let healthPingInterval: Duration = .seconds(10)
    /// The health ping's deadline (RN `HEALTH_TIMEOUT_MS`).
    public nonisolated static let healthTimeout: Duration = HouseholdClient.healthTimeout
    /// Coming back to the app re-reads lists at most this often; also the least time between two
    /// recovery refreshes (RN `RESUME_REFRESH_MS`).
    public nonisolated static let resumeRefreshInterval: Duration = .seconds(5)
    /// How long failures last before the state is `offline` (RN `delay.reconnect`).
    public nonisolated static let offlineDelay: Duration = .milliseconds(Motion.delay.reconnect)

    /// `local` without a session, otherwise the tracked state.
    public private(set) var state: ConnectionState = .local
    /// Bumped on every transition into `offline`, when the reconnecting copy is announced: a
    /// view can follow it with `.onChange` instead of passing an announcer.
    public private(set) var reconnectingAnnouncements = 0

    /// What is announced on every transition into `offline` (RN `strings.connection.reconnecting`):
    /// said once here rather than by each screen's banner, which would talk over each other.
    public static var reconnectingAnnouncement: String { L10n.Connection.reconnecting }

    @ObservationIgnored private let reachability: ReachabilityHub
    @ObservationIgnored private let client: HouseholdClient
    @ObservationIgnored private let invalidator: any InventoryInvalidating
    @ObservationIgnored private let joinPreferences: HouseholdJoinPreferences
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let elapsed: @Sendable () -> Duration
    @ObservationIgnored private let announce: @MainActor @Sendable (String) -> Void

    @ObservationIgnored private var session: HouseholdSession?
    @ObservationIgnored private var sessionKey: String?
    /// The paired state as last set (RN `current`): never `local`.
    @ObservationIgnored private var tracked: ConnectionState = .online
    @ObservationIgnored private var activity: AppActivity
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var offlineTimer: Task<Void, Never>?
    @ObservationIgnored private var pingLoop: Task<Void, Never>?
    /// When the last recovery refresh ran, since this model started; nil before the first of a session.
    @ObservationIgnored private var lastRecovery: Duration?
    /// When the last resume refresh was counted; nil until the first, and never reset (process lifetime).
    @ObservationIgnored private var lastResume: Duration?

    /// - Parameters:
    ///   - reachability: the hub every household request reports to.
    ///   - client: carries the transport and the hub; the health ping goes to the session's
    ///     origin without a token.
    ///   - invalidator: re-reads every list on screen (the database model).
    ///   - joinPreferences: `markJoinedBefore()` runs for every new session.
    ///   - activity: the app's activity now; later changes come through ``activityChanged(_:)``.
    ///   - clock: drives the offline delay, the ping loop and the refresh throttles.
    ///   - announce: posts the reconnecting announcement (VoiceOver, in the app).
    public init(
        reachability: ReachabilityHub,
        client: HouseholdClient,
        invalidator: any InventoryInvalidating,
        joinPreferences: HouseholdJoinPreferences,
        activity: AppActivity = .active,
        clock: any Clock<Duration> = ContinuousClock(),
        announce: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.reachability = reachability
        self.client = client
        self.invalidator = invalidator
        self.joinPreferences = joinPreferences
        self.activity = activity
        self.clock = clock
        self.elapsed = Self.stopwatch(clock)
        self.announce = announce
    }

    /// Follows the household's session from now on, starting with the current one.
    public func follow(_ household: HouseholdModel) {
        household.addSessionObserver { [weak self] session in
            self?.sessionChanged(session)
        }
        sessionChanged(household.session)
    }

    // MARK: - Inputs

    /// A new session (joined, rejoined, left) starts from a clean slate, keyed on
    /// `origin|token` (RN ConnectionProvider.tsx:60-72, 81-89).
    public func sessionChanged(_ next: HouseholdSession?) {
        session = next
        let key = next.map { "\($0.origin)|\($0.token)" }
        guard key != sessionKey else { return }
        sessionKey = key
        subscription?.cancel()
        subscription = nil
        cancelOfflineTimer()
        tracked = .online
        lastRecovery = nil
        publish()
        if next != nil {
            joinPreferences.markJoinedBefore()
            subscribe()
        }
        evaluateResume()
        updatePingLoop()
    }

    /// The app's activity changed (RN `AppState`, ConnectionProvider.tsx:144-158): drives the
    /// resume refresh and the ping loop. Repeating the current activity does nothing.
    public func activityChanged(_ next: AppActivity) {
        guard next != activity else { return }
        activity = next
        evaluateResume()
        updatePingLoop()
    }

    /// The connection banner's "Try again": asks the home server now and re-reads every list
    /// (RN `retry`, ConnectionProvider.tsx:175-178).
    public func retry() {
        ping()
        invalidator.invalidate()
    }

    /// One report from the hub (RN's subscription body, ConnectionProvider.tsx:102-128).
    func report(_ reachability: Reachability) {
        guard session != nil else { return }
        switch reachability {
        case .unauthorized:
            cancelOfflineTimer()
            set(.revoked)
        case .ok:
            cancelOfflineTimer()
            // Whatever failed since the last answer (a blip that never became offline included)
            // is read again now that it can be; at most every few seconds, so one endpoint that
            // keeps failing cannot loop it.
            let recovering = tracked != .online
            set(.online)
            let now = elapsed()
            if recovering, tracked == .online, lastRecovery.map({ now - $0 >= Self.resumeRefreshInterval }) ?? true {
                lastRecovery = now
                invalidator.invalidate()
            }
        case .offline:
            guard tracked == .online, offlineTimer == nil else { return }
            set(.unsure)
            startOfflineTimer()
        }
    }

    // MARK: - State

    private func set(_ next: ConnectionState) {
        guard tracked != .revoked, tracked != next else { return }
        tracked = next
        publish()
        if next == .offline {
            reconnectingAnnouncements &+= 1
            announce(Self.reconnectingAnnouncement)
        }
        updatePingLoop()
    }

    private func publish() {
        let visible: ConnectionState = session == nil ? .local : tracked
        if state != visible { state = visible }
    }

    private func subscribe() {
        // The stream is made now, so every report from here on reaches it.
        let stream = reachability.updates()
        subscription = Task { [weak self] in
            for await value in stream {
                guard !Task.isCancelled, let self else { return }
                self.report(value)
            }
        }
    }

    private func startOfflineTimer() {
        let clock = clock
        offlineTimer = Task { [weak self] in
            do {
                try await Self.sleep(on: clock, for: Self.offlineDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.offlineTimer = nil
            self.set(.offline)
        }
    }

    private func cancelOfflineTimer() {
        offlineTimer?.cancel()
        offlineTimer = nil
    }

    // MARK: - Resume refresh and the health ping

    /// RN ConnectionProvider.tsx:149-158: on every transition to active while paired, and on
    /// every session change while active, re-read lists unless that was less than 5 s ago.
    /// The first evaluation of the process that gets this far (usually the session load
    /// resolving at launch) only starts the clock: the screens read anyway.
    private func evaluateResume() {
        guard activity.isActive, sessionKey != nil else { return }
        let now = elapsed()
        if let lastResume, now - lastResume < Self.resumeRefreshInterval { return }
        let first = lastResume == nil
        lastResume = now
        if !first { invalidator.invalidate() }
    }

    /// The ping runs only while offline and active; the first ping comes 10 s after both hold.
    private func updatePingLoop() {
        let shouldPing = session != nil && tracked == .offline && activity.isActive
        guard shouldPing else {
            pingLoop?.cancel()
            pingLoop = nil
            return
        }
        guard pingLoop == nil else { return }
        let clock = clock
        pingLoop = Task { [weak self] in
            while true {
                do {
                    try await Self.sleep(on: clock, for: Self.healthPingInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.ping()
            }
        }
    }

    /// `GET {origin}/v1/health` without a token, 5 s; the answer does not matter, the request
    /// reports reachability itself. Not waited for, like RN's interval.
    private func ping() {
        guard let session else { return }
        let client = client.withSession(origin: session.origin, token: nil)
        Task.detached {
            _ = try? await client.health(timeout: ConnectionModel.healthTimeout)
        }
    }

    // MARK: - Clock helpers

    /// Time since the model started, on `clock`.
    private nonisolated static func stopwatch<C: Clock>(_ clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    /// Opens the existential so the generic `Clock.sleep(for:tolerance:)` can be called.
    private nonisolated static func sleep<C: Clock>(on clock: C, for duration: C.Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
