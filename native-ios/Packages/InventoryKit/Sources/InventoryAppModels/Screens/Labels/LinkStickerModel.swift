import InventoryCore
import InventoryStrings
import Observation

/// Where linking a printed sticker is (RN `Phase`, `app/container/[id]/link.tsx:25-33`, 07 §3.10).
public enum LinkStickerPhase: Sendable {
    /// The camera looks for a sticker.
    case scanning
    /// The sticker is being looked up; the camera stays on, paused.
    case checking
    /// A question is up (move or replace); the camera is off until it is answered.
    case deciding
    /// The sticker is being linked.
    case linking
    /// Not one of our codes.
    case notOurs
    /// The lookup or the link failed; nothing was linked.
    case failed(any Error)

    /// The camera takes codes in this phase (RN `active` for a loaded container).
    var keepsScanning: Bool {
        switch self {
        case .scanning, .checking: true
        case .deciding, .linking, .notOurs, .failed: false
        }
    }

    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}

/// A notice over the bottom of the sticker camera (RN `Panel`, `link.tsx:47-87`): busy with a
/// spinner, or an error with the coral edge and one action. Announced when it appears.
public struct LinkStickerPanel: Sendable {
    public enum Tone: String, Sendable, Hashable {
        case busy
        case error
    }

    /// The panel's one button.
    public enum Action: String, Sendable, Hashable {
        /// The drop zone has no sticker: its tab (`link-drop-zone`).
        case goToDropZone
        /// The container could not be read: read it again (`link-try-again`).
        case reloadContainer
        /// The container is gone: close the camera (`link-back`).
        case goBack
        /// Not one of ours: scan again (`link-scan-again`).
        case scanAgain
        /// The lookup or the link failed: scan again (`link-try-again`).
        case tryAgain

        public var label: String {
            switch self {
            case .goToDropZone: L10n.Errors.DropZoneLocked.action
            case .reloadContainer, .tryAgain: L10n.Common.tryAgain
            case .goBack: L10n.Common.goBack
            case .scanAgain: L10n.Camera.scanAgain
            }
        }

        /// RN's testID, kept as the accessibility identifier.
        public var identifier: String {
            switch self {
            case .goToDropZone: "link-drop-zone"
            case .reloadContainer, .tryAgain: "link-try-again"
            case .goBack: "link-back"
            case .scanAgain: "link-scan-again"
            }
        }
    }

    public var tone: Tone
    public var title: String?
    public var message: String
    public var action: Action?

    public init(tone: Tone, title: String? = nil, message: String, action: Action? = nil) {
        self.tone = tone
        self.title = title
        self.message = message
        self.action = action
    }

    /// What VoiceOver announces when the panel appears: `"<title>. <message>"`, or the message.
    public var announcement: String {
        title.map { "\($0). \(message)" } ?? message
    }
}

/// Where the sticker camera sends the person.
public enum LinkStickerNavigation: Sendable, Hashable {
    /// Close the camera, back to the QR label screen (RN `router.back()`).
    case close
    /// The drop zone's tab (RN `goToTab('/drop-zone')`).
    case dropZoneTab
}

/// Links a sticker printed earlier to a container: point the camera at it and it is linked, with
/// a question first only when an existing link would stop working (RN
/// `app/container/[id]/link.tsx`, 07 §3.10, §5.5).
///
/// A full-screen camera over the QR label screen that closes back to it with a toast. It reads
/// the container with its label token (`containers.getWithCounts`, key `container:<id>`), owns
/// its ``scanner`` (which the view runs with its own focus handling) and keeps it active only
/// while the container is loaded, it is not the drop zone, and it is scanning or checking.
/// ``close()`` (the cover went away) keeps a late answer from closing anything or saying
/// anything, except that a link which then finishes is still told in a toast.
@MainActor
@Observable
public final class LinkStickerModel {
    public let containerId: String
    /// `containers.getWithCounts(id)`, key `container:<id>`.
    public let container: InventoryQuery<ContainerWithCounts?>
    /// The camera part (title "Scan the sticker", torch, permission).
    public let scanner: QrScannerModel
    public private(set) var phase: LinkStickerPhase = .scanning

    private let qr: @MainActor @Sendable () -> any QrRepository
    private let invalidator: any InventoryInvalidating
    private let toasts: any ToastPresenting
    private let confirm: any ConfirmPresenting
    private let haptics: HapticPlayer
    private let telemetry: TelemetryReporter
    private let navigate: @MainActor @Sendable (LinkStickerNavigation) -> Void

    @ObservationIgnored private var isOpen = true
    /// "Reading the sticker…" shows only once the lookup has run 180 ms (RN `useDelayedFlag`).
    @ObservationIgnored private let checkingDelay: DelayedFlag

    /// - Parameters:
    ///   - permission: The camera permission (purpose `scan`).
    ///   - read: `containers.getWithCounts(id)`, nil when the container is gone.
    ///   - qr: The QR repository in use now (local, or the household's).
    ///   - revision: The global revision now.
    ///   - clock: The reticle lock and the 180 ms busy delay.
    public init(
        containerId: String,
        permission: CameraPermissionModel,
        read: @escaping @Sendable (String) async throws -> ContainerWithCounts?,
        qr: @escaping @MainActor @Sendable () -> any QrRepository,
        revision: Int = 0,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        confirm: any ConfirmPresenting,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        clock: any Clock<Duration> = ContinuousClock(),
        navigate: @escaping @MainActor @Sendable (LinkStickerNavigation) -> Void
    ) {
        self.containerId = containerId
        self.qr = qr
        self.invalidator = invalidator
        self.toasts = toasts
        self.confirm = confirm
        self.haptics = haptics
        self.telemetry = telemetry
        self.navigate = navigate
        checkingDelay = DelayedFlag(clock: clock)
        container = InventoryQuery(key: "container:\(containerId)", revision: revision) { try await read(containerId) }
        // Off until the container is known (RN `active` needs it).
        scanner = QrScannerModel(title: L10n.Link.titlePlain, permission: permission, active: false, clock: clock)
        scanner.onScan = { [weak self] raw in await self?.link(raw) }
        container.onSettle = { [weak self] in self?.syncScanner() }
    }

    /// ``init(containerId:permission:read:qr:revision:invalidator:toasts:confirm:haptics:telemetry:clock:navigate:)``
    /// reading through `repositories` (`app.repositories`).
    public convenience init(
        containerId: String,
        permission: CameraPermissionModel,
        repositories: some InventoryRepositories,
        revision: Int = 0,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        confirm: any ConfirmPresenting,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        clock: any Clock<Duration> = ContinuousClock(),
        navigate: @escaping @MainActor @Sendable (LinkStickerNavigation) -> Void
    ) {
        let containers = repositories.containers
        let qr = repositories.qr
        self.init(
            containerId: containerId,
            permission: permission,
            read: { try await containers.getWithCounts($0) },
            qr: { qr },
            revision: revision,
            invalidator: invalidator,
            toasts: toasts,
            confirm: confirm,
            haptics: haptics,
            telemetry: telemetry,
            clock: clock,
            navigate: navigate
        )
    }

    // MARK: Derived state

    /// The drop zone is a tab, not a box with a sticker on it.
    public var isLocked: Bool { containerId == DropZone.containerId }

    /// The container once read (RN `containerQuery.data`, null until then and when gone).
    public var loaded: ContainerWithCounts? { container.data ?? nil }

    /// The camera takes codes: the container is known, not the drop zone, and scanning or
    /// checking (RN `active`).
    // RN: app/container/[id]/link.tsx:111-113
    public var isActive: Bool { !isLocked && loaded != nil && phase.keepsScanning }

    /// "Reading the sticker…" is due: the lookup has run 180 ms.
    public var showsChecking: Bool { checkingDelay.value }

    /// The scanner's title: "Scan the sticker for Tool chest", or "Scan the sticker" while the
    /// container loads.
    public var title: String {
        guard let loaded else { return L10n.Link.titlePlain }
        return L10n.Link.title(label: ContainerRules.labelOf(name: loaded.name, shortCode: loaded.shortCode))
    }

    /// The notice over the camera, by RN's precedence (07 §3.10 "Panel precedence"); nil while
    /// scanning, and while a lookup has run less than 180 ms.
    // RN: app/container/[id]/link.tsx:188-240
    public var panel: LinkStickerPanel? {
        if isLocked {
            return LinkStickerPanel(
                tone: .error,
                title: L10n.Errors.DropZoneLocked.title,
                message: L10n.Errors.DropZoneLocked.body,
                action: .goToDropZone
            )
        }
        if loaded == nil, let cause = container.cause {
            let described = describeError(cause, context: .read, subject: .container)
            return LinkStickerPanel(tone: .error, title: described.title, message: described.body, action: .reloadContainer)
        }
        if loaded == nil, !container.isLoading {
            // Deleted, probably on another phone, while this was opening.
            return LinkStickerPanel(tone: .error, title: L10n.Errors.Gone.container, message: L10n.Errors.Gone.body, action: .goBack)
        }
        switch phase {
        case .notOurs:
            return LinkStickerPanel(tone: .error, title: L10n.Camera.NotOurs.title, message: L10n.Camera.NotOurs.body, action: .scanAgain)
        case .failed(let cause):
            // Read wording for both steps: nothing was linked, and nothing was lost.
            let described = describeError(cause, context: .read, subject: .container)
            return LinkStickerPanel(tone: .error, title: described.title, message: described.body, action: .tryAgain)
        case .linking:
            return LinkStickerPanel(tone: .busy, message: L10n.Link.linking)
        case .scanning, .checking, .deciding:
            return showsChecking ? LinkStickerPanel(tone: .busy, message: L10n.Link.checking) : nil
        }
    }

    // MARK: Reads

    /// The screen gained or lost focus.
    public func focusChanged(_ focused: Bool, revision: Int? = nil) {
        container.focusChanged(focused, revision: revision)
        syncScanner()
    }

    /// The global revision changed.
    public func revisionChanged(_ revision: Int) {
        container.revisionChanged(revision)
    }

    // MARK: Actions

    /// The panel's button.
    public func perform(_ action: LinkStickerPanel.Action) {
        switch action {
        case .goToDropZone: navigate(.dropZoneTab)
        case .reloadContainer: container.reload()
        case .goBack: navigate(.close)
        case .scanAgain, .tryAgain: setPhase(.scanning)
        }
    }

    /// "Scan again" and "Try again": the camera looks again, re-armed.
    public func scanAgain() {
        setPhase(.scanning)
    }

    /// The cover went away (popped, dismissed or replaced): an answer arriving later closes
    /// nothing. Call it from `router.onRemoval(of:)`, never `onDisappear`.
    // RN: app/container/[id]/link.tsx:115-124
    public func close() {
        isOpen = false
    }

    /// A sticker the scanner handed over (RN `link`, 07 §3.10).
    ///
    /// Reads what it opens (`qr.resolveScan`) and plans with
    /// ``ContainerRules/planSticker(_:target:)``: not ours says so; one that already opens this
    /// container closes with "This sticker already opens …"; a move, or replacing the
    /// container's own label, asks first (Cancel goes back to scanning); then `qr.bind`,
    /// `qr_bound`, invalidate, the success haptic, close, and "Sticker linked to …". A failure
    /// shows on the panel, or in a toast once the camera has closed. Closing while reading writes
    /// nothing and says nothing.
    // RN: app/container/[id]/link.tsx:126-182
    public func link(_ raw: String) async {
        // The scanner only runs once the container is known.
        guard let target = loaded else { return }
        setPhase(.checking)
        let label = ContainerRules.labelOf(name: target.name, shortCode: target.shortCode)
        let repository = qr()

        let plan: StickerPlan
        do {
            plan = ContainerRules.planSticker(try await repository.resolveScan(raw), target: target)
        } catch {
            if isOpen {
                haptics(.error)
                setPhase(.failed(error))
            }
            return
        }
        // Closed while reading: nothing was written, so nothing to say.
        guard isOpen else { return }

        switch plan {
        case .invalid:
            haptics(.error)
            setPhase(.notOurs)
        case .already:
            haptics(.success)
            navigate(.close)
            toasts.show(ToastOptions(message: L10n.Link.already(label: label)))
        case .link(let token, let question):
            if let question {
                setPhase(.deciding)
                guard await confirm.confirm(question), isOpen else {
                    // Pointed at the wrong sticker, probably: carry on scanning.
                    setPhase(.scanning)
                    return
                }
            }
            setPhase(.linking)
            do {
                _ = try await repository.bind(token: token, containerId: target.id)
            } catch {
                haptics(.error)
                // The panel says it; with the camera already closed, a toast does.
                if isOpen {
                    setPhase(.failed(error))
                } else {
                    toasts.show(ToastOptions(message: L10n.Link.notLinked(label: label), tone: .error))
                }
                return
            }
            telemetry.event("qr_bound")
            invalidator.invalidate()
            haptics(.success)
            // Linked even if the camera was closed meanwhile: still say so, but only this
            // screen closes.
            if isOpen { navigate(.close) }
            toasts.show(ToastOptions(message: L10n.Link.linked(label: label)))
        }
    }

    // MARK: Internals

    private func setPhase(_ next: LinkStickerPhase) {
        phase = next
        checkingDelay.setActive(next.isChecking)
        syncScanner()
    }

    private func syncScanner() {
        scanner.setActive(isActive)
    }
}
