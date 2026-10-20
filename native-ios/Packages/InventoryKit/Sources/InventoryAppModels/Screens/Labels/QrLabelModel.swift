import InventoryCore
import InventoryStrings
import Observation

/// What the QR label screen shows, in RN's render order (RN `app/container/[id]/qr.tsx:241-304`,
/// 07 §3.9). The drop zone never gets this far: the screen shows the locked state for it and
/// builds no model.
public enum QrLabelScreenState: Sendable {
    /// The container, or whether it has a label, is not known yet: the detail skeleton.
    case loading
    /// The container could not be read: the error state, whose Try again reads both again.
    case containerFailed(any Error)
    /// The container read answered nothing: gone (deleted on another phone), with Go to Spaces.
    case containerGone
    /// Whether there is a label could not be read, and nothing says so: the error state. The
    /// screen never offers "Make" then, because a wrong one would retire a printed sticker.
    case labelFailed(any Error)
    /// No label: make one, or link a sticker printed earlier.
    case noLabel(Container)
    /// The label to print or share, with Replace and Remove.
    case label(Container, token: String)
}

/// A container's QR label (RN `app/container/[id]/qr.tsx`, 07 §3.9): show it to print or share,
/// replace or remove it when the sticker is lost, or make one, or link a sticker printed earlier.
///
/// Two reads, the container (`container:<id>`) and its label (`qr-of:<id>`), driven by the
/// screen's focus and the revision through ``focusChanged(_:revision:)`` and
/// ``revisionChanged(_:)``. Nothing is offered until both have been read, and the label on screen
/// follows what this screen just wrote until a read set off afterwards has come back
/// (``ContainerRules/settleWrittenLabel(_:loading:failed:)``), so a make, replace or remove never
/// flashes the previous state and a failed read never brings back a retired sticker. Every write
/// is caught and told in a toast.
@MainActor
@Observable
public final class QrLabelModel {
    /// The reads behind the screen.
    public struct Reads: Sendable {
        /// `containers.getById(id)`: nil when it is gone.
        public var container: @Sendable (String) async throws -> Container?
        /// `qr.getByContainer(id)`: the container's newest label, nil when it has none.
        public var binding: @Sendable (String) async throws -> QrBinding?

        public init(
            container: @escaping @Sendable (String) async throws -> Container?,
            binding: @escaping @Sendable (String) async throws -> QrBinding?
        ) {
            self.container = container
            self.binding = binding
        }

        /// The repositories in use at each call (`app.repositories`).
        public init(repositories: some InventoryRepositories) {
            let containers = repositories.containers
            let qr = repositories.qr
            self.init(
                container: { try await containers.getById($0) },
                binding: { try await qr.getByContainer($0) }
            )
        }
    }

    public let containerId: String
    /// `containers.getById(id)`, key `container:<id>`.
    public let container: InventoryQuery<Container?>
    /// `qr.getByContainer(id)`, key `qr-of:<id>`.
    public let binding: InventoryQuery<QrBinding?>
    /// The label change under way: its own row spins, and every action (Share too) waits.
    public private(set) var busy: QrLabelAction?
    /// The label this screen last wrote (a nil token after a remove), until a read started
    /// after the write has come back (RN `useShownToken`).
    public private(set) var written: WrittenLabel?
    /// The label has been read successfully at least once. Until then the screen cannot say
    /// there is none; afterwards a reload keeps what is on screen (RN `labelKnown`).
    public private(set) var labelKnown = false

    private let qr: @MainActor @Sendable () -> any QrRepository
    private let invalidator: any InventoryInvalidating
    private let toasts: any ToastPresenting
    private let confirm: any ConfirmPresenting
    private let haptics: HapticPlayer
    private let telemetry: TelemetryReporter

    /// - Parameters:
    ///   - reads: The container and its label (``Reads/init(repositories:)``).
    ///   - qr: The QR repository in use now, for the writes.
    ///   - revision: The global revision now.
    public init(
        containerId: String,
        reads: Reads,
        qr: @escaping @MainActor @Sendable () -> any QrRepository,
        revision: Int = 0,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        confirm: any ConfirmPresenting,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared
    ) {
        self.containerId = containerId
        self.qr = qr
        self.invalidator = invalidator
        self.toasts = toasts
        self.confirm = confirm
        self.haptics = haptics
        self.telemetry = telemetry
        let readContainer = reads.container
        let readBinding = reads.binding
        container = InventoryQuery(key: "container:\(containerId)", revision: revision) { try await readContainer(containerId) }
        binding = InventoryQuery(key: "qr-of:\(containerId)", revision: revision) { try await readBinding(containerId) }
        binding.onSettle = { [weak self] in self?.settle() }
    }

    // MARK: Derived state

    /// The label on screen: the one just written, else the one read.
    public var shownToken: String? {
        if let written { return written.token }
        return (binding.data ?? nil)?.token
    }

    /// What to show (07 §3.9 "Render order").
    // RN: app/container/[id]/qr.tsx:241-304
    public var state: QrLabelScreenState {
        guard let stored = container.data ?? nil else {
            if let cause = container.cause { return .containerFailed(cause) }
            if container.isLoading { return .loading }
            return .containerGone
        }
        // Not knowing whether there is a label is said as such: offering "Make a QR label" here
        // could retire a sticker that is on the box.
        if written == nil, (binding.data ?? nil) == nil, let cause = binding.cause { return .labelFailed(cause) }
        if !labelKnown { return .loading }
        if let token = shownToken { return .label(stored, token: token) }
        return .noLabel(stored)
    }

    /// "This could not be refreshed" over what was loaded before: the container's refresh failed,
    /// or the label's did while the screen is not showing its own write. Offline and revoked have
    /// their own banners.
    public var showsRefreshBanner: Bool {
        needsRefreshBanner(container.refreshFailed, cause: container.cause)
            || (written == nil && needsRefreshBanner(binding.refreshFailed, cause: binding.cause))
    }

    // MARK: Reads

    /// The screen gained or lost focus (both reads follow it).
    public func focusChanged(_ focused: Bool, revision: Int? = nil) {
        container.focusChanged(focused, revision: revision)
        binding.focusChanged(focused, revision: revision)
        settle()
    }

    /// The global revision changed.
    public func revisionChanged(_ revision: Int) {
        container.revisionChanged(revision)
        binding.revisionChanged(revision)
        settle()
    }

    /// Try again and the refresh banner's action: both reads again.
    public func reloadAll() {
        container.reload()
        binding.reload()
        settle()
    }

    // MARK: Actions

    /// "Make a QR label": looks first (a label may have been linked or made elsewhere since the
    /// screen read "none"), then binds a fresh token. No question: there is nothing to replace.
    public func make() async {
        await makeLabel(.make)
    }

    /// "Replace label…": asks first, then binds a fresh token; the old sticker stops opening the
    /// container.
    public func replace() async {
        await makeLabel(.replace)
    }

    /// Makes a label (none yet) or replaces it (asked first).
    // RN: app/container/[id]/qr.tsx:138-173
    private func makeLabel(_ action: QrLabelAction) async {
        guard begin(action) else { return }
        defer { end() }
        let repository = qr()
        do {
            if action == .replace {
                let confirmed = await confirm.confirm(ConfirmOptions(
                    title: L10n.Qr.replaceTitle,
                    body: L10n.Qr.replaceBody,
                    confirmLabel: L10n.Qr.replaceConfirm
                ))
                guard confirmed else { return }
            } else if let current = try await repository.getByContainer(containerId) {
                // "No QR label yet" was a moment old: show the label it has, and make none.
                wrote(current.token)
                toasts.show(ToastOptions(message: L10n.Qr.alreadyLabelled))
                return
            }
            let made = try await repository.createAndBind(containerId)
            telemetry.event("qr_generated")
            invalidator.invalidate()
            wrote(made.token)
            haptics(.success)
            if action == .replace { toasts.show(ToastOptions(message: L10n.Qr.made)) }
        } catch {
            haptics(.error)
            toasts.show(ToastOptions(message: ContainerRules.labelFailureMessage(action, cause: error), tone: .error))
        }
    }

    /// "Remove label…": asks first, then unlinks the sticker; the container and everything in it
    /// stay. An unbind that finds nothing (removed on another phone) is the same end state.
    // RN: app/container/[id]/qr.tsx:176-198
    public func remove() async {
        guard begin(.remove) else { return }
        defer { end() }
        do {
            let confirmed = await confirm.confirm(ConfirmOptions(
                title: L10n.Qr.removeTitle,
                body: L10n.Qr.removeBody,
                confirmLabel: L10n.Qr.removeConfirm
            ))
            guard confirmed else { return }
            _ = try await qr().unbind(containerId)
            telemetry.event("qr_unbound")
            invalidator.invalidate()
            wrote(nil)
            haptics(.success)
            toasts.show(ToastOptions(message: L10n.Qr.removed))
        } catch {
            haptics(.error)
            toasts.show(ToastOptions(message: ContainerRules.labelFailureMessage(.remove, cause: error), tone: .error))
        }
    }

    // MARK: Internals

    /// One action at a time (RN `begin`): false while another runs.
    private func begin(_ action: QrLabelAction) -> Bool {
        guard busy == nil else { return false }
        busy = action
        return true
    }

    private func end() {
        busy = nil
    }

    /// The screen shows `token` from now on, until a read started after this write comes back.
    ///
    /// The label is read again at once, as RN's "already labelled" path did and its revision bump
    /// did for the others: here the revision reaches the reads only once the view reports it, and
    /// a read still running from before the write must not be the one that ends the hold (it would
    /// bring back the retired label for a moment).
    private func wrote(_ token: String?) {
        written = WrittenLabel(token: token, reloading: false)
        binding.reload()
        settle()
    }

    /// Applies the label read's state to what is shown, and latches ``labelKnown``.
    // RN: app/container/[id]/qr.tsx:48-62, :111-112
    private func settle() {
        let next = ContainerRules.settleWrittenLabel(written, loading: binding.isLoading, failed: binding.cause != nil)
        if next != written { written = next }
        if !labelKnown, !binding.isLoading, binding.cause == nil { labelKnown = true }
    }
}
