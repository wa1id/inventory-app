import InventoryCore
import InventoryStrings
import Observation

/// New container in a known space: its type, and a name only if wanted, since an unnamed
/// container goes by the code on its label (RN app/container/new.tsx; 07 §3.6).
///
/// It opens straight away, replacing this sheet, because a new container is there to be filled.
/// From the place picker (with a request) it is handed back instead, and the sheet closes in the
/// same step, so the picker files into it. There is no validation: a blank name makes an unnamed
/// container. While the space loads, or when its read failed, the form still works, just without
/// the "In Garage" line; a space found gone has nothing to add to.
@MainActor
@Observable
public final class ContainerNewModel {
    /// Where the sheet goes once the container exists.
    public enum Navigation: Sendable, Hashable {
        /// The opener took the container: close the sheet (in the same step as the delivery).
        case close
        /// Nobody waited: open the container in place of this sheet (RN `router.replace`).
        case openContainer(id: String)
    }

    /// The type a new container starts as (RN `DEFAULT_TYPE`).
    public static let defaultType: ContainerVisualType = .box

    public let spaceId: String
    /// `spaces.getById(spaceId)` (key `space:<id>`), for the context line.
    public let space: InventoryQuery<Space?>
    /// Asks before typing is thrown away; the view keeps ``DirtyGuard/revoked`` current.
    public let dirtyGuard: DirtyGuard

    public private(set) var name = ""
    public private(set) var visualType: ContainerVisualType = ContainerNewModel.defaultType
    /// The last create that did not happen, shown as the notice.
    public private(set) var failure: PlacesSaveFailure?
    public private(set) var isSaving = false

    @ObservationIgnored private let request: RouteRequest<NewContainerResult>?
    @ObservationIgnored private let routeResults: RouteResults?
    @ObservationIgnored private let containers: any ContainersRepository
    @ObservationIgnored private let invalidator: any InventoryInvalidating
    @ObservationIgnored private let toasts: any ToastPresenting
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let telemetry: TelemetryReporter
    @ObservationIgnored private let isFocused: @MainActor () -> Bool
    @ObservationIgnored private let navigate: @MainActor (Navigation) -> Void

    /// - Parameters:
    ///   - request: the opener's request, answered with a ``NewContainerResult`` through `routeResults`.
    ///   - isFocused: whether the sheet is still in front (RN `navigation.isFocused()`).
    public init(
        spaceId: String,
        request: RouteRequest<NewContainerResult>?,
        routeResults: RouteResults?,
        spaces: any SpacesRepository,
        containers: any ContainersRepository,
        revision: Int = 0,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        confirm: any ConfirmPresenting,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        isFocused: @escaping @MainActor () -> Bool,
        navigate: @escaping @MainActor (Navigation) -> Void
    ) {
        self.spaceId = spaceId
        self.request = request
        self.routeResults = routeResults
        self.containers = containers
        self.invalidator = invalidator
        self.toasts = toasts
        self.haptics = haptics
        self.telemetry = telemetry
        self.isFocused = isFocused
        self.navigate = navigate
        space = InventoryQuery(key: PlacesReads.spaceKey(spaceId), revision: revision, read: PlacesReads.space(spaces, id: spaceId))
        dirtyGuard = DirtyGuard(confirm: confirm)
    }

    // MARK: Outputs

    /// The space, once read.
    public var spaceData: Space? { space.data ?? nil }

    /// The space read answered nothing: deleted, probably on another phone (RN
    /// `spaceData === null && !loading && !cause`). Never while it loads or after a failure.
    public var isSpaceGone: Bool {
        spaceData == nil && !space.isLoading && space.cause == nil
    }

    /// "In Garage", once the space is known.
    public var contextLine: String? {
        spaceData.map { L10n.ContainerForm.inSpace(space: $0.name) }
    }

    /// A typed name or another type is worth asking about.
    public var isDirty: Bool {
        EntityText.hasText(name) || !EntityText.same(visualType.rawValue, Self.defaultType.rawValue)
    }

    /// The failed create's banner (a gone container's words, as a household 404 means).
    public var notice: SaveNoticeCopy? { failure?.notice(subject: .container) }

    // MARK: Inputs

    /// Typing clears a failed create's notice.
    public func setName(_ next: String) {
        name = next
        failure = nil
        syncGuard()
    }

    /// A new type clears a failed create's notice.
    public func setVisualType(_ next: ContainerVisualType) {
        visualType = next
        failure = nil
        syncGuard()
    }

    public func focusChanged(_ focused: Bool, revision: Int?) {
        space.focusChanged(focused, revision: revision)
    }

    public func revisionChanged(_ revision: Int) {
        space.revisionChanged(revision)
    }

    // MARK: Creating

    /// Create container, or Return in the name. One at a time: a double submit makes one.
    public func save() async {
        guard !isSaving else { return }
        isSaving = true
        failure = nil
        syncGuard()
        do {
            // The repository trims the name and stores a blank one as NULL.
            let container = try await containers.create(CreateContainerInput(spaceId: spaceId, name: name, visualType: visualType))
            telemetry.event("container_created")
            invalidator.invalidate()
            haptics(.success)
            guard isFocused() else {
                // The header Cancel closed the sheet mid-save: navigating now would act on whatever
                // is in front, and a waiting picker was already told nothing came of it. The
                // container is made, and the list in front refreshes to show it.
                toasts.show(ToastOptions(message: L10n.ContainerForm.created(
                    label: SpaceSetup.containerLabel(name: container.name, shortCode: container.shortCode)
                )))
                return
            }
            // Delivered and closed in the same step: the picker (and the Move sheet under it, which
            // closes only while it is in front) resumes after this sheet is gone.
            if routeResults?.deliver(request, NewContainerResult(container)) == true {
                navigate(.close)
            } else {
                navigate(.openContainer(id: container.id))
            }
        } catch {
            isSaving = false
            syncGuard()
            haptics(.error)
            if isFocused() {
                failure = PlacesSaveFailure(cause: error)
            } else {
                toasts.show(ToastOptions(message: L10n.ContainerForm.notCreated(offline: isOffline(error)), tone: .error))
            }
        }
    }

    private func syncGuard() {
        dirtyGuard.dirty = isDirty
        dirtyGuard.saving = isSaving
    }
}
