import InventoryCore
import InventoryServices
import InventoryStrings
import Observation

/// Edit container: rename, retype or move it to another space, or delete it
/// (RN app/container/[id]/edit.tsx; 07 §3.8).
///
/// The label code stays as it is, because it is printed. The form is seeded once per id, so a
/// background refresh never overwrites typing; a stored type this build does not know stays
/// selected-as-nothing and is written back unchanged. Save sends the name as typed (the
/// repository trims it and stores an emptied one as NULL, so the container goes by its code
/// again); it is not gated on a change, and containers carry no lock (07 §0.2). A container
/// deleted elsewhere is never a fake success. Delete asks first, saying what goes with it, then
/// closes everything and opens the space it was in, so a container opened from search or a label
/// never stays in the stack.
@MainActor
@Observable
public final class ContainerEditModel {
    /// Where the sheet goes.
    public enum Navigation: Sendable, Hashable {
        /// Saved: close the sheet (only while it is still in front).
        case close
        /// Deleted: close every sheet and pushed screen, then open the space it was in
        /// (RN `router.dismissAll(); router.push('/space/<id>')`).
        case openSpace(id: String)
    }

    /// What the screen shows instead of the form while there is no stored container.
    public enum Blocking: Sendable {
        case failed(any Error)
        case loading
        /// Read fine, but nothing there: deleted, probably on another phone.
        case gone
    }

    /// The space list under "Space".
    public enum SpaceChoice: Sendable {
        case options([SpaceWithCounts])
        /// The list could not be read: a warning banner with Try again.
        case failed(ErrorCopy)
        case loading
    }

    private struct Seed {
        let id: String
        let values: ContainerFormValues
    }

    public let id: String
    /// `containers.getById(id)` (key `container:<id>`).
    public let container: InventoryQuery<Container?>
    /// `spaces.listWithCounts()` (key `spaces`), the spaces it can move to.
    public let spaces: InventoryQuery<[SpaceWithCounts]>
    /// Asks before typing is thrown away; the view keeps ``DirtyGuard/revoked`` current.
    public let dirtyGuard: DirtyGuard

    public private(set) var values = ContainerFormValues(name: "", visualType: .box, spaceId: "")
    /// The last save that did not happen; a nil cause means the container is gone.
    public private(set) var failure: PlacesSaveFailure?
    public private(set) var busy: PlacesFormBusy?

    @ObservationIgnored private var seed: Seed?
    @ObservationIgnored private let containers: any ContainersRepository
    @ObservationIgnored private let photos: any PhotoStoring
    @ObservationIgnored private let invalidator: any InventoryInvalidating
    @ObservationIgnored private let toasts: any ToastPresenting
    @ObservationIgnored private let confirm: any ConfirmPresenting
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let telemetry: TelemetryReporter
    @ObservationIgnored private let isFocused: @MainActor () -> Bool
    @ObservationIgnored private let navigate: @MainActor (Navigation) -> Void

    /// - Parameters:
    ///   - photos: deletes the photo files a delete orphaned.
    ///   - isFocused: whether the sheet is still in front (RN `navigation.isFocused()`).
    public init(
        id: String,
        spaces spacesRepository: any SpacesRepository,
        containers: any ContainersRepository,
        photos: any PhotoStoring,
        revision: Int = 0,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        confirm: any ConfirmPresenting,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        isFocused: @escaping @MainActor () -> Bool,
        navigate: @escaping @MainActor (Navigation) -> Void
    ) {
        self.id = id
        self.containers = containers
        self.photos = photos
        self.invalidator = invalidator
        self.toasts = toasts
        self.confirm = confirm
        self.haptics = haptics
        self.telemetry = telemetry
        self.isFocused = isFocused
        self.navigate = navigate
        container = InventoryQuery(key: PlacesReads.containerKey(id), revision: revision) { try await containers.getById(id) }
        spaces = InventoryQuery(key: PlacesReads.spacesKey, revision: revision, read: PlacesReads.spacesWithCounts(spacesRepository))
        dirtyGuard = DirtyGuard(confirm: confirm)
        container.onSettle = { [weak self] in self?.containerSettled() }
    }

    // MARK: Outputs

    /// The container as last read; nil before the first read and once it is gone.
    public var stored: Container? { container.data ?? nil }

    public var isGone: Bool { failure?.isGone ?? false }

    /// The form differs from the stored container (RN `dirty`).
    public var isDirty: Bool {
        guard stored != nil, let seed, !isGone else { return false }
        return SpaceSetup.containerValuesChanged(values, initial: seed.values)
    }

    /// Instead of the form: the read failed, is loading, or found nothing.
    public var blocking: Blocking? {
        guard stored == nil else { return nil }
        if let cause = container.cause { return .failed(cause) }
        return container.isLoading ? .loading : .gone
    }

    /// The spaces to choose from, the failure to explain, or the wait.
    public var spaceChoice: SpaceChoice {
        if let rows = spaces.data { return .options(rows) }
        if let cause = spaces.cause { return .failed(describeError(cause)) }
        return .loading
    }

    /// What the toasts call the container: its name, or else its code (RN `containerLabel`).
    public var label: String {
        stored.map { SpaceSetup.containerLabel(name: $0.name, shortCode: $0.shortCode) } ?? values.name
    }

    /// "The label code stays D R W, 7 K 2 M, because it is printed on the label."
    public var codeAccessibilityLabel: String? {
        stored.map { L10n.ContainerForm.codeStays(code: spellCode($0.shortCode)) }
    }

    public var isSaving: Bool { busy == .save }
    public var isDeleting: Bool { busy == .delete }
    public var isSaveDisabled: Bool { busy == .delete || isGone }
    public var isDeleteDisabled: Bool { busy == .save || isGone }

    /// The failed save's banner; it offers Spaces when the container is gone.
    public var notice: SaveNoticeCopy? { failure?.notice(subject: .container) }

    // MARK: Inputs

    public func setName(_ name: String) {
        change { $0.name = name }
    }

    public func setVisualType(_ visualType: ContainerVisualType) {
        change { $0.visualType = visualType }
    }

    public func setSpace(_ spaceId: String) {
        change { $0.spaceId = spaceId }
    }

    /// Try again under "Space".
    public func retrySpaces() {
        spaces.reload()
    }

    public func focusChanged(_ focused: Bool, revision: Int?) {
        container.focusChanged(focused, revision: revision)
        spaces.focusChanged(focused, revision: revision)
    }

    public func revisionChanged(_ revision: Int) {
        container.revisionChanged(revision)
        spaces.revisionChanged(revision)
    }

    // MARK: Saving

    /// Save changes, or Return in the name.
    public func save() async {
        guard busy == nil else { return }
        busy = .save
        failure = nil
        syncGuard()
        let values = values
        let label = label
        do {
            let input = UpdateContainerInput(name: .set(values.name), visualType: values.visualType, spaceId: values.spaceId)
            guard try await containers.update(id, input) != nil else {
                fail(nil, label: label)
                return
            }
            telemetry.event("container_updated")
            invalidator.invalidate()
            if isFocused() { navigate(.close) }
            toasts.show(ToastOptions(message: L10n.ContainerForm.saved))
        } catch {
            fail(error, label: label)
        }
    }

    private func fail(_ cause: (any Error)?, label: String) {
        release()
        haptics(.error)
        if isFocused() {
            failure = PlacesSaveFailure(cause: cause)
            syncGuard()
            return
        }
        let message = cause.map { L10n.ContainerForm.notSaved(label: label, offline: isOffline($0)) } ?? L10n.ContainerForm.alreadyDeleted(label: label)
        toasts.show(ToastOptions(message: message, tone: .error))
    }

    // MARK: Deleting

    /// Delete container…: asks first, saying what goes with it.
    public func delete() async {
        guard busy == nil, let current = stored else { return }
        busy = .delete
        syncGuard()
        let label = SpaceSetup.containerLabel(name: current.name, shortCode: current.shortCode)
        do {
            let impact = try await containers.deletionImpact(id)
            let confirmed = await confirm.confirm(ConfirmOptions(
                title: L10n.ContainerForm.deleteTitle(label: label),
                body: SpaceSetup.containerDeleteBody(impact),
                confirmLabel: L10n.Common.delete
            ))
            guard confirmed else {
                release()
                return
            }
            let result = try await containers.delete(id)
            // Nothing deleted means another phone deleted it first: neither counted nor claimed.
            if result.deleted {
                photos.deleteStoredPhotos(result.orphanedPhotoUris.map(Optional.some))
                telemetry.event("container_deleted", ["itemCount": .int(impact.itemCount)])
            }
            invalidator.invalidate()
            // The space it was stored in, not the one the form may have been switched to.
            navigate(.openSpace(id: current.spaceId))
            toasts.show(ToastOptions(
                message: result.deleted ? L10n.ContainerForm.deleted(label: label) : L10n.ContainerForm.alreadyDeleted(label: label)
            ))
        } catch {
            release()
            haptics(.error)
            toasts.show(ToastOptions(message: L10n.ContainerForm.deleteFailed(label: label, offline: isOffline(error)), tone: .error))
        }
    }

    // MARK: Private

    private func change(_ edit: (inout ContainerFormValues) -> Void) {
        if !isGone { failure = nil }
        edit(&values)
        syncGuard()
    }

    /// Seeds the form from the loaded container once per id.
    private func containerSettled() {
        if let stored, !EntityText.same(seed?.id, stored.id) {
            let initial = ContainerFormValues(name: stored.name ?? "", visualType: stored.visualType, spaceId: stored.spaceId)
            seed = Seed(id: stored.id, values: initial)
            values = initial
        }
        syncGuard()
    }

    private func release() {
        busy = nil
        syncGuard()
    }

    private func syncGuard() {
        dirtyGuard.dirty = isDirty
        dirtyGuard.saving = busy != nil
    }
}
