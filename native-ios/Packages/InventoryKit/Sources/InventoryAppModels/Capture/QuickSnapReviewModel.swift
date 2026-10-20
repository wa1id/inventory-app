import InventoryCore
import InventoryServices
import InventoryStrings
import Observation

/// Where the Quick Snap review goes (05 §3, §6.5).
public enum QuickSnapReviewNavigation: Sendable, Hashable {
    /// Done: back to where the set started (Home, the Drop zone, a container), or, when there is
    /// nothing to go back to, open the container (RN `router.canGoBack() ? back : openContainer`).
    case leave(containerId: String)
    /// Keep shooting: replace the review with the camera, same set.
    case keepShooting(CaptureRoute)
    /// Nothing was saved, Try again: replace the review with a fresh camera.
    case tryAgain(CaptureRoute)
    /// A row: the item screen, as a filing run for the drop zone (RN `/item/<id>?filing=1`).
    case openItem(id: String, filing: Bool)
    /// The Done toast's View: the Drop zone tab.
    case viewDropZone
}

/// What the review shows where its list would be (RN `review.tsx:250-272`).
public enum QuickSnapReviewPlaceholder: Sendable {
    /// Rows are on screen: no placeholder.
    case none
    /// A skeleton of this many 76 pt rows: the first read is pending, or photos are still on
    /// their way and none has landed.
    case skeleton(rows: Int)
    /// The first read failed: the error state with Try again (``QuickSnapReviewModel/reload()``).
    case error(any Error)
    /// Every row landed and then left (deleted, or filed elsewhere): `strings.review.emptied`.
    case emptied
    /// Nothing landed: `strings.review.nothing`, whose action is ``QuickSnapReviewModel/tryAgain()``.
    case nothing
}

/// The end of a Quick Snap set (RN `app/capture/review.tsx`, 05 §6): what it saved, what still
/// needs a name, and the way back.
///
/// The model holds no session state of its own beyond what RN derived: the rows are a filtered
/// read of the container (``read()``), re-run whenever the screen gains focus, the revision
/// changes while it is in front, or the person pulls to refresh, as with every `InventoryQuery`
/// (key ``queryKey``). The view reports those triggers with ``focusChanged(_:revision:)``,
/// ``revisionChanged(_:)`` and ``refresh()``; ``reload()`` is Try again. A read that finishes
/// after a newer one started is dropped. Rows therefore appear when their pipeline finishes, as
/// in RN (05 §6.1, Q14).
///
/// "Saving N more…" holds only while the set changes: a 30 s timer on the injected clock restarts
/// whenever a row lands, is named or goes, and when it fires the status becomes "Some photos may
/// not have been saved." (05 §6.3).
@MainActor
@Observable
public final class QuickSnapReviewModel {
    /// How long a set may sit unchanged before "Saving N more…" stops promising (RN `STALL_MS`).
    public static let stallDuration: Duration = .milliseconds(30_000)

    public let route: QuickSnapReviewRoute

    /// The last read's rows (the set, oldest first), before hidden rows are removed; nil until the
    /// first read succeeds.
    public private(set) var loaded: [ItemWithContext]?
    /// Why the latest read failed, or nil when it did not.
    public private(set) var cause: (any Error)?
    /// A read is running.
    public private(set) var isLoading = false
    /// Rows deleted here, hidden until the next fresh read.
    public private(set) var hidden: QuickSnapHiddenRows?
    /// Every row id the set has shown.
    public private(set) var landed: Set<String> = []
    /// The signature the stall timer fired for.
    public private(set) var quietSignature: String?

    private let items: any ItemsRepository
    private let photos: any PhotoStoring
    private let isPaired: @MainActor @Sendable () -> Bool
    private let invalidator: any InventoryInvalidating
    private let toasts: any ToastPresenting
    private let confirm: any ConfirmPresenting
    private let haptics: HapticPlayer
    private let telemetry: TelemetryReporter
    private let clock: any Clock<Duration>
    private let navigate: @MainActor @Sendable (QuickSnapReviewNavigation) -> Void

    @ObservationIgnored private var readSource = 0
    @ObservationIgnored private var readToken = 0
    @ObservationIgnored private var deleting = false
    @ObservationIgnored private var leaving = false
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var stallArmedFor: (signature: String, waiting: Bool)?
    /// Whether the screen is in front, as the view last said.
    @ObservationIgnored private var isFocused = false
    /// The revision the rows were last read for (RN `seenRevision`).
    @ObservationIgnored private var seenRevision: Int?
    /// The newest revision the view reported.
    @ObservationIgnored private var latestRevision: Int?
    /// The read a focus gain, a revision change or a refresh started (tests await it).
    @ObservationIgnored public private(set) var readTask: Task<Void, Never>?

    /// - Parameters:
    ///   - items: The items repository in use now (local, or the household's).
    ///   - photos: Deletes the files a delete orphaned.
    ///   - isPaired: Whether a household session exists now (the delete confirm's wording).
    ///   - clock: Drives the 30 s stall timer.
    public init(
        route: QuickSnapReviewRoute,
        items: any ItemsRepository,
        photos: any PhotoStoring,
        isPaired: @escaping @MainActor @Sendable () -> Bool,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        confirm: any ConfirmPresenting,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        clock: any Clock<Duration> = ContinuousClock(),
        navigate: @escaping @MainActor @Sendable (QuickSnapReviewNavigation) -> Void
    ) {
        self.route = route
        self.items = items
        self.photos = photos
        self.isPaired = isPaired
        self.invalidator = invalidator
        self.toasts = toasts
        self.confirm = confirm
        self.haptics = haptics
        self.telemetry = telemetry
        self.clock = clock
        self.navigate = navigate
    }

    // MARK: Reading

    /// The query's identity (RN `fast-review:<containerId>:<since>`).
    public var queryKey: String { "fast-review:\(route.containerId):\(route.since)" }

    /// The set: the container's rows created at or after `since`, oldest first (RN
    /// `sessionItems(await listByContainer(containerId), since)`).
    // RN: app/capture/review.tsx:81-84
    public func read() async throws -> [ItemWithContext] {
        FastReview.sessionItems(try await items.listByContainer(route.containerId), since: route.since)
    }

    /// Reads the set again. On success the rows replace the old ones and hiding from the old read
    /// is forgotten; on failure the old rows stay, with ``refreshFailed`` (RN `useInventoryQuery`).
    public func reload() async {
        readToken += 1
        let token = readToken
        isLoading = true
        // RN's `cause` belongs to the settled read: none while a new one runs.
        cause = nil
        // RN armed the timer on mount, before the first read: nothing shown yet, all expected.
        rearmStall()
        do {
            let rows = try await read()
            guard token == readToken else { return }
            received(rows)
        } catch {
            guard token == readToken else { return }
            cause = error
        }
        isLoading = false
        rearmStall()
    }

    /// The screen gained or lost focus (RN `useInventoryQuery`'s focus effect). Gaining it reads
    /// again, catching up with `revision` (or the newest one reported), as one read; a screen
    /// behind the item screen or a sheet reads nothing until it is in front again. While focused,
    /// a newer revision reads too. The same shape as `InventoryQuery.focusChanged(_:revision:)`,
    /// so the shell's focus driving can run it.
    // RN: src/hooks/useInventoryQuery.ts:28-52
    public func focusChanged(_ focused: Bool, revision: Int? = nil) {
        if let revision { latestRevision = revision }
        let gained = focused && !isFocused
        isFocused = focused
        guard focused, gained || latestRevision != seenRevision else { return }
        seenRevision = latestRevision
        startRead()
    }

    /// The database revision changed (a pipeline landed, Done on the camera, a delete): read again,
    /// only while in front (RN re-ran the query on `invalidate()` while focused).
    public func revisionChanged(_ revision: Int) {
        latestRevision = revision
        guard isFocused, revision != seenRevision else { return }
        seenRevision = revision
        startRead()
    }

    /// Pull to refresh: reads again and returns once that read has settled.
    public func refresh() async {
        startRead()
        await readTask?.value
    }

    private func startRead() {
        readTask = Task { [weak self] in
            await self?.reload()
        }
    }

    /// A settled read, applied as RN's derived state did (`landed` grows, hiding resets).
    private func received(_ rows: [ItemWithContext]) {
        readSource += 1
        loaded = rows
        cause = nil
        landed = CaptureFlow.withLanded(landed, rows)
    }

    // MARK: Derived state

    /// A refresh failed while rows stay on screen.
    public var refreshFailed: Bool { cause != nil && loaded != nil }

    /// The "could not be refreshed" banner over stale rows; never for offline or a removed phone,
    /// which have their own surfaces (RN `needsRefreshBanner`).
    public var showsRefreshBanner: Bool { needsRefreshBanner(refreshFailed, cause: cause) }

    /// The rows on screen: the last read without the rows deleted here.
    public var list: [ItemWithContext] {
        CaptureFlow.visibleRows(loaded ?? [], hidden: hidden, source: readSource)
    }

    /// The camera's count less the rows that landed and have left since.
    public var expectedStillShown: Int {
        CaptureFlow.expectedStillShown(expected: route.expected, landed: landed.count, shown: list.count)
    }

    public var summary: FastSessionSummary {
        FastReview.summarize(list, expected: expectedStillShown)
    }

    /// What the set's rows call their container (over the rows before hiding).
    public var label: String? { CaptureFlow.containerLabel(loaded ?? []) }

    /// Changes when a row lands, is named or goes (over the rows before hiding).
    public var signature: String { CaptureFlow.sessionSignature(loaded ?? []) }

    public var status: QuickSnapReviewStatus {
        let summary = summary
        let waiting = summary.pending > 0
        return CaptureFlow.reviewStatus(summary, stalled: waiting && quietSignature == signature)
    }

    /// The title, or nil (a container whose rows have not landed has no title).
    public var title: String? {
        CaptureFlow.reviewTitle(summary, status: status, containerId: route.containerId, label: label)
    }

    /// The status line under the title (a polite live region; alert tone when ``status`` is
    /// `maybeLost`).
    public var statusText: String { CaptureFlow.reviewStatusText(status, summary) }

    /// The title block shows once data has loaded and there are rows or photos still saving:
    /// nothing is claimed before the first read.
    public var showsHeader: Bool {
        loaded != nil && (!list.isEmpty || status == .pending)
    }

    /// What stands in for the list when it is empty.
    public var placeholder: QuickSnapReviewPlaceholder {
        if !list.isEmpty { return .none }
        let skeleton = QuickSnapReviewPlaceholder.skeleton(rows: min(max(summary.pending, 1), 4))
        guard loaded != nil else {
            if let cause { return .error(cause) }
            return skeleton
        }
        if status == .pending { return skeleton }
        return landed.isEmpty ? .nothing : .emptied
    }

    // MARK: Actions

    /// Opens a row: a filing run for the drop zone, the item screen otherwise.
    public func openItem(_ id: String) {
        navigate(.openItem(id: id, filing: route.containerId == DropZone.containerId))
    }

    /// Deletes a row after a confirm (RN `remove`). One at a time: a second trash tap while the
    /// question is open does nothing. A row another phone deleted first still leaves the list but
    /// is not counted as deleted here.
    // RN: app/capture/review.tsx:142-172
    public func delete(_ id: String) async {
        guard !deleting else { return }
        deleting = true
        defer { deleting = false }

        let confirmed = await confirm.confirm(ConfirmOptions(
            title: L10n.Review.deleteTitle,
            body: isPaired() ? L10n.Review.deleteBodyPaired : L10n.Review.deleteBodyLocal,
            confirmLabel: L10n.Common.delete
        ))
        guard confirmed else { return }

        do {
            let result = try await items.delete(id)
            if result.deleted {
                photos.deleteStoredPhotos(result.orphanedPhotoUris)
                telemetry.event("item_deleted")
            }
            // Hidden in the list as last drawn: a pipeline may have re-read the set while the
            // question was open.
            hidden = CaptureFlow.hideRow(hidden, source: readSource, id: id)
            invalidator.invalidate()
            rearmStall()
        } catch {
            let kind = describeError(error, context: .delete, subject: .item).kind
            telemetry.error("item_delete_failed", ["errorClass": .string(kind.rawValue)])
            haptics(.error)
            toasts.show(ToastOptions(message: L10n.Review.deleteFailed(offline: kind == .offline), tone: .error))
        }
    }

    /// Done: logs `fast_review_done`, goes back and says where the items are; the drop zone's
    /// toast offers View (RN `done`). Done, Keep shooting and Try again each leave once.
    // RN: app/capture/review.tsx:184-202
    public func done() {
        guard !leaving else { return }
        leaving = true
        let summary = summary
        telemetry.event("fast_review_done", ["kept": .int(summary.saved), "unnamed": .int(summary.unnamed)])
        let report = CaptureFlow.reviewDoneToast(saved: summary.saved, containerId: route.containerId, label: label)
        navigate(.leave(containerId: route.containerId))
        guard let report else { return }
        let navigate = navigate
        toasts.show(ToastOptions(
            message: report.message,
            action: report.viewDropZone
                ? ToastAction(label: L10n.Common.view, accessibilityLabel: L10n.Review.viewDropZoneA11y) { navigate(.viewDropZone) }
                : nil
        ))
    }

    /// Keep shooting: back to the camera for the same set (RN `keepShooting`).
    ///
    /// The camera carries the set's start and the photos still expected here, less the rows that
    /// landed and have left, so the next review keeps waiting for shots still in flight
    /// (DECISIONS U6; RN carried only `since`, so the count restarted at zero, 05 C7).
    // RN: app/capture/review.tsx:204-209
    public func keepShooting() {
        guard !leaving else { return }
        leaving = true
        navigate(.keepShooting(CaptureRoute(
            containerId: route.containerId,
            mode: .fast,
            since: route.since,
            expectedBase: expectedStillShown
        )))
    }

    /// Nothing was saved: a fresh camera, a new set (RN `tryAgain`).
    // RN: app/capture/review.tsx:211-216
    public func tryAgain() {
        guard !leaving else { return }
        leaving = true
        navigate(.tryAgain(CaptureRoute(containerId: route.containerId, mode: .fast)))
    }

    // MARK: Stall timer

    /// RN's effect on `[signature, waiting]`: restarts the 30 s timer whenever either changes while
    /// photos are pending; when it fires, records the signature it was armed for.
    // RN: app/capture/review.tsx:123-130
    private func rearmStall() {
        let signature = signature
        let waiting = summary.pending > 0
        if let armed = stallArmedFor, armed.signature == signature, armed.waiting == waiting { return }
        stallArmedFor = (signature, waiting)
        stallTask?.cancel()
        stallTask = nil
        guard waiting else { return }
        stallTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: Self.stallDuration)
            } catch {
                return
            }
            // Re-armed after this wait ended but before it ran: the set changed, so it is not quiet.
            guard !Task.isCancelled else { return }
            self?.quietSignature = signature
        }
    }
}
