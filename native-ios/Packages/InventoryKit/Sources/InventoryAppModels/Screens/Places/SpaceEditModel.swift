import InventoryCore
import InventoryServices
import InventoryStrings
import Observation

/// Edit space: rename, re-icon or recolour a space, or delete it with everything in it
/// (RN app/space/[id]/edit.tsx; 07 §3.13).
///
/// The form is seeded once per id from the first read, so a background refresh never
/// overwrites typing. Save writes all three fields every time (it is not gated on a change, and
/// spaces carry no lock: the last writer wins, 07 §0.2). A space deleted elsewhere is never a
/// fake success: the save answers nil, the notice says so and offers Spaces, and Save and Delete
/// stay off. Delete asks first and spells out what goes with it, QR labels included; every step
/// can fail over the network, so all of it is caught and told.
@MainActor
@Observable
public final class SpaceEditModel {
    /// Where the sheet goes.
    public enum Navigation: Sendable, Hashable {
        /// Saved: close the sheet (only while it is still in front).
        case close
        /// Deleted: the Spaces tab, with everything presented closed (RN `goToTab('/spaces')`).
        case goToSpaces
    }

    /// What the screen shows instead of the form while there is no stored space.
    public enum Blocking: Sendable {
        case failed(any Error)
        case loading
        /// Read fine, but nothing there: deleted, probably on another phone.
        case gone
    }

    private struct Seed {
        let id: String
        let values: SpaceFormValues
    }

    public let id: String
    /// `spaces.getById(id)` (key `space:<id>`).
    public let space: InventoryQuery<Space?>
    /// `spaces.listWithCounts()` (key `spaces`), only for the preview row's counts.
    public let counts: InventoryQuery<[SpaceWithCounts]>
    /// Asks before typing is thrown away; the view keeps ``DirtyGuard/revoked`` current.
    public let dirtyGuard: DirtyGuard

    /// What the fields hold; blank until the space is read.
    public private(set) var values = SpaceFormValues(name: "", icon: "", color: "")
    public private(set) var nameError: String?
    /// The last save that did not happen; a nil cause means the space is gone.
    public private(set) var failure: PlacesSaveFailure?
    public private(set) var busy: PlacesFormBusy?
    /// Goes up each time the name field should take focus (a blank name on Save).
    public private(set) var nameFocusRequests = 0

    @ObservationIgnored private var seed: Seed?
    @ObservationIgnored private let spaces: any SpacesRepository
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
        spaces: any SpacesRepository,
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
        self.spaces = spaces
        self.containers = containers
        self.photos = photos
        self.invalidator = invalidator
        self.toasts = toasts
        self.confirm = confirm
        self.haptics = haptics
        self.telemetry = telemetry
        self.isFocused = isFocused
        self.navigate = navigate
        space = InventoryQuery(key: PlacesReads.spaceKey(id), revision: revision, read: PlacesReads.space(spaces, id: id))
        counts = InventoryQuery(key: PlacesReads.spacesKey, revision: revision, read: PlacesReads.spacesWithCounts(spaces))
        dirtyGuard = DirtyGuard(confirm: confirm)
        space.onSettle = { [weak self] in self?.spaceSettled() }
    }

    // MARK: Outputs

    /// The space as last read; nil before the first read and once it is gone.
    public var stored: Space? { space.data ?? nil }

    /// The space was found gone by a save.
    public var isGone: Bool { failure?.isGone ?? false }

    /// The form differs from the stored space (RN `dirty`).
    public var isDirty: Bool {
        guard stored != nil, let seed, !isGone else { return false }
        return SpaceSetup.spaceValuesChanged(values, initial: seed.values)
    }

    /// Instead of the form: the read failed, is loading, or found nothing.
    public var blocking: Blocking? {
        guard stored == nil else { return nil }
        if let cause = space.cause { return .failed(cause) }
        return space.isLoading ? .loading : .gone
    }

    /// The preview row's counts, or nil (no preview) while they load.
    public var previewMeta: String? {
        guard let row = counts.data?.first(where: { EntityText.same($0.id, id) }) else { return nil }
        return L10n.Entities.spaceCounts(containers: row.containerCount, items: row.itemCount)
    }

    /// The preview's name while the field is empty: the stored one, never another room's.
    public var previewFallbackName: String { stored?.name ?? "" }

    public var isSaving: Bool { busy == .save }
    public var isDeleting: Bool { busy == .delete }
    public var isSaveDisabled: Bool { busy == .delete || isGone }
    public var isDeleteDisabled: Bool { busy == .save || isGone }

    /// The failed save's banner; it offers Spaces when the space is gone.
    public var notice: SaveNoticeCopy? { failure?.notice(subject: .space) }

    // MARK: Inputs

    /// The fields changed (RN `change`): a new name clears its error; any change clears the
    /// failure unless the space is gone.
    public func change(_ next: SpaceFormValues) {
        if !EntityText.same(next.name, values.name) { nameError = nil }
        if !isGone { failure = nil }
        values = next
        syncGuard()
    }

    public func focusChanged(_ focused: Bool, revision: Int?) {
        space.focusChanged(focused, revision: revision)
        counts.focusChanged(focused, revision: revision)
    }

    public func revisionChanged(_ revision: Int) {
        space.revisionChanged(revision)
        counts.revisionChanged(revision)
    }

    // MARK: Saving

    /// Save changes, or Return in the name. A blank name asks for one.
    public func save() async {
        guard busy == nil else { return }
        guard EntityText.hasText(values.name) else {
            nameError = L10n.SpaceForm.nameRequired
            nameFocusRequests += 1
            return
        }
        busy = .save
        failure = nil
        syncGuard()
        let values = values
        let name = stored?.name ?? values.name
        do {
            let input = UpdateSpaceInput(name: values.name.jsTrimmed(), icon: values.icon, color: values.color)
            guard try await spaces.update(id, input) != nil else {
                fail(nil, name: name)
                return
            }
            telemetry.event("space_updated")
            invalidator.invalidate()
            // Only from the front: closing again after the header Cancel closed the sheet
            // mid-save would close whatever is in front instead.
            if isFocused() { navigate(.close) }
            toasts.show(ToastOptions(message: L10n.SpaceForm.saved))
        } catch {
            fail(error, name: name)
        }
    }

    /// A save that did not happen: the banner, or a toast once the sheet has closed.
    private func fail(_ cause: (any Error)?, name: String) {
        release()
        haptics(.error)
        if isFocused() {
            failure = PlacesSaveFailure(cause: cause)
            syncGuard()
            return
        }
        let message = cause.map { L10n.SpaceForm.notSaved(name: name, offline: isOffline($0)) } ?? L10n.SpaceForm.alreadyDeleted(name: name)
        toasts.show(ToastOptions(message: message, tone: .error))
    }

    // MARK: Deleting

    /// Delete space…: asks first, saying exactly what goes with it.
    public func delete() async {
        guard busy == nil, let current = stored else { return }
        busy = .delete
        syncGuard()
        let spaces = spaces
        let containers = containers
        let id = id
        do {
            async let impactRead = spaces.deletionImpact(id)
            async let containersRead = containers.listBySpace(id)
            let impact = try await impactRead
            let inSpace = try await containersRead
            // A household reports no label count; the containers' own tokens make up for it.
            let labels = SpaceSetup.labelsInSpace(impactLabels: impact.qrBindingCount, containers: inSpace)
            let confirmed = await confirm.confirm(ConfirmOptions(
                title: L10n.SpaceForm.deleteTitle(name: current.name),
                body: SpaceSetup.spaceDeleteBody(containerCount: impact.containerCount, itemCount: impact.itemCount, labels: labels),
                confirmLabel: L10n.Common.delete
            ))
            guard confirmed else {
                release()
                return
            }
            let result = try await spaces.delete(id)
            // Nothing deleted means another phone deleted it first: gone either way, but this
            // phone did not do it, so it is neither counted nor claimed.
            if result.deleted {
                photos.deleteStoredPhotos(result.orphanedPhotoUris.map(Optional.some))
                telemetry.event("space_deleted", [
                    "containerCount": .int(impact.containerCount),
                    "itemCount": .int(impact.itemCount),
                ])
            }
            invalidator.invalidate()
            navigate(.goToSpaces)
            toasts.show(ToastOptions(
                message: result.deleted ? L10n.SpaceForm.deleted(name: current.name) : L10n.SpaceForm.alreadyDeleted(name: current.name)
            ))
        } catch {
            release()
            haptics(.error)
            toasts.show(ToastOptions(message: L10n.SpaceForm.deleteFailed(name: current.name, offline: isOffline(error)), tone: .error))
        }
    }

    // MARK: Private

    /// Seeds the form from the loaded space once per id (RN seeds during render).
    private func spaceSettled() {
        if let stored, !EntityText.same(seed?.id, stored.id) {
            let initial = SpaceFormValues(name: stored.name, icon: stored.icon, color: stored.color)
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
