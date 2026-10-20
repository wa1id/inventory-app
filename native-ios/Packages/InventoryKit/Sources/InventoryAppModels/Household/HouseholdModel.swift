import Foundation
import Observation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage

/// Whether this phone is part of a household, and the household's repositories when it is
/// (RN: src/providers/HouseholdProvider.tsx; 04 §5, 09 §4.2).
///
/// The boot gate waits for ``ready`` so a paired phone never flashes its local inventory.
///
/// **Session changes.** ``session`` is observable, so views follow it directly. Models that must
/// react to every change in order, like ``ConnectionModel``, register with
/// ``addSessionObserver(_:)``: observers run synchronously on the main actor right after
/// ``session`` changes (the keychain load resolving, a pairing, a disconnect), never for an
/// assignment of the same value. ``ConnectionModel/follow(_:)`` does that registration.
///
/// Changing the session does not re-read any list by itself; callers invalidate after
/// ``pair(bootstrapSecret:deviceName:)`` and ``disconnect(revokeDevice:)`` (09 §4.1).
@MainActor
@Observable
public final class HouseholdModel {
    /// Whether protected data (the `WhenUnlocked` keychain item) can be read yet
    /// (InventoryStorage's ``ProtectedData`` in the app; a stand-in in tests).
    public struct ProtectedDataGate: Sendable {
        public var isAvailable: @MainActor @Sendable () -> Bool
        public var waitUntilAvailable: @MainActor @Sendable () async -> Void

        public init(
            isAvailable: @escaping @MainActor @Sendable () -> Bool,
            waitUntilAvailable: @escaping @MainActor @Sendable () async -> Void
        ) {
            self.isAvailable = isAvailable
            self.waitUntilAvailable = waitUntilAvailable
        }

        /// `UIApplication.isProtectedDataAvailable` and its notification.
        public static let live = ProtectedDataGate(
            isAvailable: { ProtectedData.isAvailable },
            waitUntilAvailable: { await ProtectedData.waitUntilAvailable() }
        )
    }

    /// A registration made with ``addSessionObserver(_:)``.
    public struct SessionObservation: Hashable, Sendable {
        fileprivate let id: UUID
    }

    /// How long leaving waits for the home server to drop this phone (RN `LEAVE_TIMEOUT_MS`):
    /// leaving must stay instant offline.
    public nonisolated static let leaveRevokeTimeout: Duration = .seconds(5)

    /// The household session, or nil while unpaired (and until ``ready``).
    public private(set) var session: HouseholdSession?
    /// False until the stored session has been read; the boot gate waits for it.
    public private(set) var ready = false
    /// A join form is joining, from its checks passing to its end (``beginJoining()``). One per
    /// app, not per form: a form made again while the first still pairs (onboarding's Join step
    /// after Back, Household opened again after going back) must not pair this phone a second
    /// time, which would register it twice (DECISIONS U6; RN's guard was per form).
    public private(set) var isJoining = false

    /// The pairing client: the build's household origin, no token. Its transport, reachability
    /// hub and clock carry over to every session client.
    public let client: HouseholdClient

    @ObservationIgnored private let store: HouseholdSessionStore
    @ObservationIgnored private let photos: any PhotoStoring
    @ObservationIgnored private let photoCache: HouseholdPhotoCache
    @ObservationIgnored private let protectedData: ProtectedDataGate
    @ObservationIgnored private var observers: [(id: UUID, notify: @MainActor (HouseholdSession?) -> Void)] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Bumped by every pairing and disconnect, so a slow keychain load never overwrites them.
    @ObservationIgnored private var sessionChanges = 0
    /// The last best-effort revoke a disconnect started (for tests).
    @ObservationIgnored private(set) var pendingRevoke: Task<Void, Never>?

    /// - Parameters:
    ///   - store: the `household.session.v1` keychain item.
    ///   - client: aimed at `AppConfig.householdOrigin`, without a token.
    ///   - photos: reads local captures for the household item-create upload.
    ///   - photoCache: where household photos become local files.
    ///   - protectedData: the keychain is read only once protected data is available.
    public init(
        store: HouseholdSessionStore,
        client: HouseholdClient,
        photos: any PhotoStoring,
        photoCache: HouseholdPhotoCache,
        protectedData: ProtectedDataGate = .live
    ) {
        self.store = store
        self.client = client
        self.photos = photos
        self.photoCache = photoCache
        self.protectedData = protectedData
    }

    /// The household repositories for the current session (RN `repos`), rebuilt from the session
    /// on every read; nil while unpaired. Screens use ``RepositoryProvider/repositories``, which
    /// adds the local shadow.
    public var remoteRepositories: HTTPRepositories? {
        session.map { HTTPRepositories(session: $0, client: client, photos: photos, photoCache: photoCache) }
    }

    /// A client for the current session (the phone list, removing a phone); nil while unpaired.
    public var sessionClient: HouseholdClient? {
        session.map(client.forSession)
    }

    // MARK: - Load

    /// Reads the stored session, then sets ``ready`` (RN HouseholdProvider.tsx:34-46).
    ///
    /// The keychain item is `WhenUnlocked`, so it is read only once protected data is available;
    /// before that the phone is neither paired nor unpaired and ``ready`` stays false (00-index
    /// §5, 09 §3.2). A read that fails while protected data is available reads as unpaired, as
    /// in RN; one that fails because the device locked again waits for the next unlock. A corrupt
    /// item reads as unpaired and is left in place. Calling it again waits for the same load.
    public func load() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        let changesBefore = sessionChanges
        while true {
            await protectedData.waitUntilAvailable()
            let store = store
            let outcome = await Task.detached { () -> Result<HouseholdSession?, any Error> in
                do {
                    return .success(try store.loadReportingErrors())
                } catch {
                    return .failure(error)
                }
            }.value
            let stored: HouseholdSession?
            switch outcome {
            case .success(let session):
                stored = session
            case .failure:
                guard protectedData.isAvailable() else { continue }
                stored = nil
            }
            // A pairing or disconnect that finished meanwhile is newer than what was read.
            if sessionChanges == changesBefore { apply(stored) }
            ready = true
            return
        }
    }

    // MARK: - Pair and disconnect

    /// Claims the one join that may run (``isJoining``); false while another join runs. Pair
    /// with ``endJoining()``.
    public func beginJoining() -> Bool {
        guard !isJoining else { return false }
        isJoining = true
        return true
    }

    /// The join claimed with ``beginJoining()`` has finished, whatever it came to.
    public func endJoining() {
        isJoining = false
    }

    /// Joins the household with its code, saves the session and switches to it
    /// (RN `pair`, HouseholdProvider.tsx:50-54).
    ///
    /// `POST /v1/pair` goes to the build's household origin; from then on every request goes to
    /// the origin the server answered with. The session is published as soon as it is saved,
    /// which swaps the Household screen to its paired view before the join form has finished
    /// (04 §5), so the caller's join task must not belong to the form's view.
    ///
    /// The request and the save run to the end even when the caller's task is cancelled (a join
    /// screen going away), as RN's did: aborting `POST /v1/pair` after the server registered the
    /// phone would leave a device row this phone has no token for, and the next attempt would
    /// register it a second time.
    ///
    /// - Throws: the pairing's ``HouseholdHttpError`` (a 401 is a refused code), or the
    ///   keychain's error when the session could not be saved. In that last case the server has
    ///   already registered the phone, which then shows in the household's list (RN parity).
    public func pair(bootstrapSecret: String, deviceName: String) async throws {
        let (client, store) = (client, store)
        let next = try await Task.detached {
            let pairing = try await client.pair(bootstrapSecret: bootstrapSecret, deviceName: deviceName)
            let session = HouseholdSession(pairing: pairing)
            try store.save(session)
            return session
        }.value
        sessionChanges += 1
        apply(next)
    }

    /// Forgets the session: deletes the keychain item and goes unpaired at once
    /// (RN `disconnect`, HouseholdProvider.tsx:56-59, plus app/household.tsx:216-225).
    ///
    /// With `revokeDevice` (leaving the household), the home server is then told to drop this
    /// phone, best effort and not waited for: `DELETE /v1/devices/<this phone>` with the old
    /// token and a 5 s deadline, errors ignored, so leaving is instant offline and the
    /// household's list of phones stays tidy when it can. The session is forgotten first, so a
    /// request still in flight that comes back 401 cannot flash the removed-phone layer over a
    /// phone leaving on purpose.
    ///
    /// The removed-phone layer passes `revokeDevice: false`: that token is already dead (04 §9.6).
    /// Local SQLite (shadow rows included) and the photo cache are kept.
    public func disconnect(revokeDevice: Bool = true) {
        let previous = session
        store.clear()
        sessionChanges += 1
        apply(nil)
        guard revokeDevice, let previous else { return }
        let client = client.forSession(previous)
        pendingRevoke = Task.detached {
            try? await client.revokeDevice(id: previous.deviceId, timeout: HouseholdModel.leaveRevokeTimeout)
        }
    }

    // MARK: - Observers

    /// Calls `observer` on the main actor after every change of ``session``, in registration order.
    @discardableResult
    public func addSessionObserver(_ observer: @escaping @MainActor (HouseholdSession?) -> Void) -> SessionObservation {
        let id = UUID()
        observers.append((id, observer))
        return SessionObservation(id: id)
    }

    /// Stops calling an observer.
    public func removeSessionObserver(_ observation: SessionObservation) {
        observers.removeAll { $0.id == observation.id }
    }

    private func apply(_ next: HouseholdSession?) {
        guard next != session else { return }
        session = next
        for observer in observers {
            observer.notify(next)
        }
    }
}
