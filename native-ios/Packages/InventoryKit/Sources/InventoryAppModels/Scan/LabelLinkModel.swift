import InventoryCore
import InventoryStrings
import Observation

/// What the label screen shows (RN `app/c/[token].tsx` rendering, 06 §9.2).
public enum LabelLinkState: Sendable {
    /// No answer yet for this attempt, or a linked label about to be replaced by its container:
    /// the detail skeleton labelled `strings.deepLink.opening`.
    case resolving
    /// The lookup failed: the error state, whose Try again is ``LabelLinkModel/retry()``.
    case failed(any Error)
    /// Not one of our labels: the empty state with Go to Home (``LabelLinkModel/goHome()``).
    case invalid
    /// Ours but not linked: `strings.deepLink.newTitle` / `.newBody` over the place picker in
    /// bind mode; a pick calls ``LabelLinkModel/link(_:)``. `token` is the lowercased token.
    case unknown(token: String)
}

/// Where the label screen sends the person.
public enum LabelLinkNavigation: Sendable, Hashable {
    /// Replace this screen with the container, if it is still the top of its stack.
    case replaceWithContainer(id: String)
    /// The drop zone is a tab, never a container screen (RN `goToTab('/drop-zone')`).
    case dropZoneTab
    /// Go to Home (RN `goToTab('/')`).
    case home
}

/// A QR label opened from the iPhone Camera (`inventory://c/<token>`) or handed over by the Scan
/// tab (RN `app/c/[token].tsx`, 06 §9).
///
/// A linked label replaces the screen with its container; a label of ours that is not linked is
/// linked here to a picked container, so the token is never lost; a failed lookup offers Try
/// again. The lookup is a one-shot read that ends in navigation, so it ignores the revision and
/// focus (re-reading would replace the screen twice). ``close()`` (the screen went away) drops a
/// late answer and keeps a link that finishes afterwards from opening anything.
@MainActor
@Observable
public final class LabelLinkModel {
    /// The route's token, trimmed (`ScanRules.tokenParam(_:)`); the repository decides
    /// whether it is ours.
    public let token: String
    public private(set) var state: LabelLinkState = .resolving
    /// The picked container being linked: its row spins and the list locks.
    public private(set) var busyId: String?

    private let qr: @MainActor @Sendable () -> any QrRepository
    private let invalidator: any InventoryInvalidating
    private let toasts: any ToastPresenting
    private let confirm: any ConfirmPresenting
    private let haptics: HapticPlayer
    private let telemetry: TelemetryReporter
    private let rememberPlace: @MainActor @Sendable (String) -> Void
    private let navigate: @MainActor @Sendable (LabelLinkNavigation) -> Void

    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var binding = false
    @ObservationIgnored private var isOpen = true
    @ObservationIgnored private var lookup: Task<Void, Never>?

    /// - Parameters:
    ///   - token: The route's `token`, already read with `ScanRules.tokenParam(_:)`.
    ///   - qr: The QR repository in use now (local, or the household's).
    ///   - rememberPlace: Puts the linked container first among the recent places.
    public init(
        token: String,
        qr: @escaping @MainActor @Sendable () -> any QrRepository,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        confirm: any ConfirmPresenting,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        rememberPlace: @escaping @MainActor @Sendable (String) -> Void,
        navigate: @escaping @MainActor @Sendable (LabelLinkNavigation) -> Void
    ) {
        self.token = token
        self.qr = qr
        self.invalidator = invalidator
        self.toasts = toasts
        self.confirm = confirm
        self.haptics = haptics
        self.telemetry = telemetry
        self.rememberPlace = rememberPlace
        self.navigate = navigate
    }

    // MARK: Lookup

    /// Starts the lookup on first appearance; later calls do nothing (it is a one-shot read).
    public func start() {
        guard !started else { return }
        started = true
        resolve()
    }

    /// Try again after a failed lookup: a new attempt.
    public func retry() {
        guard isOpen else { return }
        attempt += 1
        state = .resolving
        resolve()
    }

    /// The screen went away: a late answer changes nothing, and a link still running opens nothing.
    ///
    /// Call it when the route leaves its stack (popped or replaced), as RN's `openRef` turned false
    /// only on unmount, never from `onDisappear`: the bind-mode picker's "New container in …"
    /// covers this screen with the container form and then picks the new container here, and
    /// that pick must still link.
    // RN: app/c/[token].tsx:56-67
    public func close() {
        isOpen = false
        lookup?.cancel()
        lookup = nil
    }

    /// Waits for the running lookup (tests; the screen never waits).
    public func waitForLookup() async {
        await lookup?.value
    }

    /// One read for this attempt (RN's effect on `request = "<token>|<attempt>"`).
    // RN: app/c/[token].tsx:81-104
    private func resolve() {
        lookup?.cancel()
        let request = attempt
        let token = token
        let repository = qr()
        lookup = Task { [weak self] in
            let result: Result<ScanOutcome, any Error>
            do {
                result = .success(try await repository.resolveScan(token))
            } catch {
                result = .failure(error)
            }
            self?.resolved(result, request: request)
        }
    }

    private func resolved(_ result: Result<ScanOutcome, any Error>, request: Int) {
        // Cancelled: the screen went away, or a newer attempt started.
        guard isOpen, request == attempt else { return }
        switch result {
        case .failure(let cause):
            telemetry.error("qr_deeplink_failed", ["errorClass": .string(describeError(cause).kind.rawValue)])
            state = .failed(cause)
        case .success(let outcome):
            switch outcome {
            case .bound(let container, _):
                telemetry.event("qr_deeplink", ["outcome": .string("bound")])
                state = .resolving
                navigate(container.id == DropZone.containerId ? .dropZoneTab : .replaceWithContainer(id: container.id))
            case .unknown(let token):
                telemetry.event("qr_deeplink", ["outcome": .string("unknown")])
                state = .unknown(token: token)
            case .invalid:
                telemetry.event("qr_deeplink", ["outcome": .string("invalid")])
                state = .invalid
            }
        }
    }

    // MARK: Actions

    /// The invalid state's Go to Home.
    public func goHome() {
        navigate(.home)
    }

    /// Links the label to the picked container (RN `link`, 06 §9.3).
    ///
    /// 1. One at a time: ignored while a link runs.
    /// 2. The container's own label is read (`qr.getByContainer`), then ``ScanRules/planBind(existing:token:label:)``.
    /// 3. Left meanwhile: nothing is written.
    /// 4. Replacing another label asks first; Cancel unlocks the list.
    /// 5. When there is something to write: `qr.bind`, `qr_bound`, invalidate.
    /// 6. The place is remembered as recent (also when it was linked meanwhile), success haptic,
    ///    the container replaces this screen if it is still open, and the "Label linked" toast
    ///    shows even if the person left. The list stays locked: the screen is being replaced.
    /// 7. Any error unlocks the list, logs `qr_bind_failed`, plays the error haptic and shows
    ///    ``ScanRules/linkFailureMessage(_:)``; the label and the list stay, so trying again is one tap.
    // RN: app/c/[token].tsx:106-144
    public func link(_ option: PlaceOption) async {
        guard case .unknown(let labelToken) = state, !binding else { return }
        binding = true
        let label = ScanRules.labelFor(option)
        busyId = option.id
        let repository = qr()

        do {
            let plan = ScanRules.planBind(existing: try await repository.getByContainer(option.id), token: labelToken, label: label)
            // Left before anything was written: they changed their mind, so nothing happens.
            guard isOpen else { return }
            if let question = plan.confirm, !(await confirm.confirm(question)) {
                binding = false
                busyId = nil
                return
            }
            if plan.write {
                _ = try await repository.bind(token: labelToken, containerId: option.id)
                telemetry.event("qr_bound")
                invalidator.invalidate()
            }
            rememberPlace(option.id)
            haptics(.success)
            // Linked even if they left meanwhile: still say so, but open nothing.
            if isOpen { navigate(.replaceWithContainer(id: option.id)) }
            toasts.show(ToastOptions(message: L10n.DeepLink.linked(label: label)))
        } catch {
            binding = false
            busyId = nil
            telemetry.error("qr_bind_failed", [
                "errorClass": .string(describeError(error, context: .label, subject: .container).kind.rawValue),
            ])
            haptics(.error)
            toasts.show(ToastOptions(message: ScanRules.linkFailureMessage(error), tone: .error))
        }
    }
}
