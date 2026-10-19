import Foundation
import Observation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryStrings

/// One phone in the Household screen's list, ready to draw (RN `PhoneRow`, app/household.tsx:377-479).
public struct HouseholdPhoneRow: Sendable, Hashable, Identifiable {
    public var device: HouseholdDevice
    /// "This phone", "Last used 3 days ago" or "Never used".
    public var meta: String
    /// This phone has no remove button; it leaves instead.
    public var isThisPhone: Bool
    /// The row read as one: `L10n.Household.phoneA11y(name:meta:)`.
    public var accessibilityLabel: String
    /// The remove button's label for other phones: `L10n.Household.removeA11y(name:)`.
    public var removeAccessibilityLabel: String?

    public var id: String { device.id }
}

/// What the Household screen shows for its phone list (RN `Phones`, app/household.tsx:377-450).
public enum HouseholdPhoneList: Sendable, Hashable {
    /// No list yet and the home server is out of reach: plain secondary text,
    /// `L10n.Household.phonesOffline` (the connection banner already offers Try again).
    case offlineNote
    /// No list yet and the read failed otherwise: a warning banner with this copy and
    /// `L10n.Common.tryAgain`, which reloads.
    case failure(ErrorCopy)
    /// No list yet, still reading: a two-row skeleton without thumbnails.
    case loading
    /// No list, nothing to say.
    case nothing
    /// The phones, this phone first. With `refreshFailed`, an info banner
    /// `L10n.Errors.refreshFailed` with `L10n.Common.tryAgain` sits above them.
    case rows([HouseholdPhoneRow], refreshFailed: Bool)
}

/// The Household screen once joined: this phone, the import offer, the other phones (and removing
/// one), and leaving (RN `Paired`, app/household.tsx:99-302; 04 §12.5-12.6).
///
/// One guard covers copying in, removing and leaving: confirmations are asynchronous, and a
/// second tap must not start a second write. The phone list itself is an inventory query the
/// view owns: ``devicesQueryKey`` and ``listDevices()`` feed it, ``phoneList(...)`` decides what
/// it shows.
@MainActor
@Observable
public final class HouseholdPairedModel {
    /// The session the screen was opened with.
    public let session: HouseholdSession
    /// The offer to copy this phone's own inventory in, read once when the screen appears.
    public private(set) var offer: ImportOffer?
    /// "Copy it into the household…" shows a spinner and "Not needed" hides.
    public private(set) var isImporting = false
    /// Why the last copy failed, in the read wording on purpose ("Nothing on this phone was
    /// lost"): a warning under the offer, assertive, not dismissible; cleared when the next copy starts.
    public private(set) var importFailure: ErrorCopy?
    /// The phone whose remove button shows a spinner.
    public private(set) var removingId: String?
    /// Why the last removal failed (delete wording; offline names the phone): a dismissible
    /// warning, assertive, at the top of the phone list; cleared when the next removal starts.
    public private(set) var removeFailure: ErrorCopy?
    /// "Leave the household…" shows a spinner.
    public private(set) var isLeaving = false

    @ObservationIgnored private let household: HouseholdModel
    @ObservationIgnored private let client: HouseholdClient
    @ObservationIgnored private let importer: HouseholdImporter
    @ObservationIgnored private let joinPreferences: HouseholdJoinPreferences
    @ObservationIgnored private let localRepositories: @MainActor () -> LocalRepositories?
    @ObservationIgnored private let invalidator: any InventoryInvalidating
    @ObservationIgnored private let toasts: any ToastPresenting
    @ObservationIgnored private let confirmer: any ConfirmPresenting
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let telemetry: TelemetryReporter
    @ObservationIgnored private var busy = false

    /// - Parameters:
    ///   - session: the household session the screen shows.
    ///   - household: forgets the session when leaving.
    ///   - client: any household client (the household model's); re-aimed at the session for the
    ///     phone list and removals.
    ///   - importer: copies the local inventory into this session's household.
    ///   - localRepositories: the raw local repositories, nil while the database is not ready.
    public init(
        session: HouseholdSession,
        household: HouseholdModel,
        client: HouseholdClient,
        importer: HouseholdImporter,
        joinPreferences: HouseholdJoinPreferences,
        localRepositories: @escaping @MainActor () -> LocalRepositories?,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        confirm: any ConfirmPresenting,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared
    ) {
        self.session = session
        self.household = household
        self.client = client.forSession(session)
        self.importer = importer
        self.joinPreferences = joinPreferences
        self.localRepositories = localRepositories
        self.invalidator = invalidator
        self.toasts = toasts
        self.confirmer = confirm
        self.haptics = haptics
        self.telemetry = telemetry
    }

    // MARK: - Status card

    /// "This phone is “Kitchen iPhone”".
    public var heading: String { L10n.Household.thisPhoneIs(name: session.deviceName) }
    /// "Part of Home."
    public var partOf: String { L10n.Household.partOf(household: session.householdName) }

    /// The dot and word on the status card (RN StatusCard, app/household.tsx:305-335): "Connected"
    /// in ink only when the home server answered; any other state, `unsure` included, reads
    /// "Reconnecting…" in the signal tone. One accessibility element, not a live region.
    public static func connectionSummary(_ state: ConnectionState) -> HouseholdStatus.Summary {
        state == .online
            ? HouseholdStatus.Summary(value: L10n.Connection.connected, tone: .ink)
            : HouseholdStatus.Summary(value: L10n.Connection.reconnectingShort, tone: .signal)
    }

    // MARK: - Import offer

    /// Reads the import offer, once per appearance of the paired view (RN app/household.tsx:110-119).
    public func readImportOffer() {
        offer = joinPreferences.importOffer
    }

    /// "Copy it into the household…" (RN `copyIn`, app/household.tsx:129-164): asks first (not a
    /// destructive confirm), then copies the raw local database into the household, clears the
    /// offer, re-reads every list and says how many items and photos went in. A failure keeps the
    /// offer (copying again is safe), logs `household_import_failed` and shows ``importFailure``.
    /// Does nothing while the database is not ready or another write is running.
    public func copyIn() async {
        guard !busy, let local = localRepositories() else { return }
        busy = true
        defer { busy = false }
        let confirmed = await confirmer.confirm(ConfirmOptions(
            title: L10n.Household.importConfirmTitle,
            body: L10n.Household.importConfirmBody,
            confirmLabel: L10n.Household.importConfirm,
            destructive: false
        ))
        guard confirmed else { return }
        isImporting = true
        importFailure = nil
        defer { isImporting = false }
        do {
            let result = try await importer.importLocalInventory(from: local.store)
            joinPreferences.clearImportOffer()
            offer = nil
            invalidator.invalidate()
            haptics(.success)
            toasts.show(ToastOptions(message: L10n.Household.copied(items: result.items, photos: result.photosUploaded)))
        } catch {
            // Never the raw message (codes like `http_500`).
            telemetry.error("household_import_failed", ["errorClass": .string(errorClass(of: error))])
            importFailure = describeError(error, context: .read)
            haptics(.error)
        }
    }

    /// "Not needed": clears the offer for good (RN app/household.tsx:166-169).
    public func notNeeded() {
        joinPreferences.clearImportOffer()
        offer = nil
    }

    // MARK: - Phones

    /// The phone list query's key (RN `devices:<deviceId>`).
    public var devicesQueryKey: String { "devices:\(session.deviceId)" }

    /// `GET /v1/devices` with the session token (RN `listDevices`).
    public func listDevices() async throws -> [HouseholdDevice] {
        try await client.listDevices()
    }

    /// Removes another phone (RN `remove`, app/household.tsx:171-201): asks first (destructive),
    /// then `DELETE /v1/devices/<id>` (a phone already gone counts as removed), logs
    /// `device_removed`, reloads the list and says so. Removing does not invalidate other lists.
    /// A failure logs `household_remove_failed` and shows ``removeFailure``.
    ///
    /// - Parameter reloadDevices: reloads the phone list query.
    public func remove(_ device: HouseholdDevice, reloadDevices: @MainActor () -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let confirmed = await confirmer.confirm(ConfirmOptions(
            title: L10n.Household.removeTitle(name: device.name),
            body: L10n.Household.removeBody,
            confirmLabel: L10n.Household.removeConfirm
        ))
        guard confirmed else { return }
        removingId = device.id
        removeFailure = nil
        defer { removingId = nil }
        do {
            try await client.revokeDevice(id: device.id)
            telemetry.event("device_removed")
            reloadDevices()
            toasts.show(ToastOptions(message: L10n.Household.removed(name: device.name)))
        } catch {
            telemetry.error("household_remove_failed", [
                "statusCode": (error as? HouseholdHttpError).map { .int($0.status) } ?? .null,
                "errorClass": .string(errorClass(of: error)),
            ])
            var copy = describeError(error, context: .delete)
            // The shared offline sentence says "What you typed is still here", which fits a form,
            // not removing a phone.
            if copy.kind == .offline { copy.body = L10n.Household.removeOffline(name: device.name) }
            removeFailure = copy
            haptics(.error)
        }
    }

    /// Puts the removal failure away.
    public func dismissRemoveFailure() {
        removeFailure = nil
    }

    /// What the phone list shows, from its query (RN `Phones`, app/household.tsx:410-450).
    ///
    /// - Parameters:
    ///   - devices: the query's data (nil before the first answer).
    ///   - loading, cause, refreshFailed: the query's state.
    ///   - connection: an unreachable home server with the connection not `online` is left to
    ///     the connection banner.
    ///   - now: epoch milliseconds, refreshed every minute while the screen is in front.
    public static func phoneList(
        devices: [HouseholdDevice]?,
        loading: Bool,
        cause: (any Error)?,
        refreshFailed: Bool,
        connection: ConnectionState,
        thisDeviceId: String,
        now: Int64
    ) -> HouseholdPhoneList {
        guard let devices else {
            if let cause {
                let described = describeError(cause, context: .read)
                if described.kind == .offline && connection != .online { return .offlineNote }
                return .failure(described)
            }
            return loading ? .loading : .nothing
        }
        let rows = HouseholdStatus.sortDevices(devices, thisDeviceId: thisDeviceId).map { device in
            let meta = HouseholdStatus.deviceMeta(device, thisDeviceId: thisDeviceId, now: now)
            let mine = device.id == thisDeviceId
            return HouseholdPhoneRow(
                device: device,
                meta: meta,
                isThisPhone: mine,
                accessibilityLabel: L10n.Household.phoneA11y(name: device.name, meta: meta),
                removeAccessibilityLabel: mine ? nil : L10n.Household.removeA11y(name: device.name)
            )
        }
        let showRefreshFailed = refreshFailed && describeError(cause, context: .read).kind != .offline
        return .rows(rows, refreshFailed: showRefreshFailed)
    }

    // MARK: - Leave

    /// "Leave the household…" (RN `leave`, app/household.tsx:203-231): asks first (destructive),
    /// then forgets the session at once and tells the home server in passing
    /// (``HouseholdModel/disconnect(revokeDevice:)``), clears the import offer, logs
    /// `household_left`, re-reads every list, leaves the screen and says so. Local data stays.
    ///
    /// - Parameter leaveScreen: goes back (or to Home), only if the screen is still in front.
    public func leave(leaveScreen: @MainActor () -> Void) async {
        guard !busy else { return }
        busy = true
        let confirmed = await confirmer.confirm(ConfirmOptions(
            title: L10n.Household.leaveTitle,
            body: L10n.Household.leaveBody,
            confirmLabel: L10n.Household.leaveConfirm
        ))
        guard confirmed else {
            busy = false
            return
        }
        // The screen goes away; like RN, the guard and the spinner are not reset.
        isLeaving = true
        household.disconnect(revokeDevice: true)
        joinPreferences.clearImportOffer()
        telemetry.event("household_left")
        invalidator.invalidate()
        leaveScreen()
        toasts.show(ToastOptions(message: L10n.Household.left))
    }
}
