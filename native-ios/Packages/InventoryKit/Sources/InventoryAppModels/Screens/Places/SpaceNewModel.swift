import InventoryCore
import InventoryStrings
import Observation

/// New space: a preset in one tap, or a name, icon and colour of one's own (RN app/space/new.tsx;
/// 07 §3.11).
///
/// Both ways end on the new space, which replaces this sheet, because making a place means
/// wanting to fill it. Opened with a request (the place picker, which had no space to offer a
/// container in), the sheet hands the new space back and closes instead, so the pick carries on.
///
/// One guard serves the presets, the button and the return key: each of them writes, and a double
/// tap would otherwise make two spaces. A custom name is not checked against the existing ones
/// (only the presets say "Already added"), as in RN. A failure keeps everything typed and shows
/// ``notice``; a sheet closed under the save (the header Cancel) hears about it in a toast.
@MainActor
@Observable
public final class SpaceNewModel {
    /// What is being created (RN `saving`: a preset's name, or `custom` for the form).
    public enum Saving: Sendable, Hashable {
        case preset(String)
        case custom
    }

    /// Where the sheet goes once the space exists.
    public enum Navigation: Sendable, Hashable {
        /// The opener took the space: close the sheet (in the same step as the delivery).
        case close
        /// Nobody waited: open the new space in place of this sheet, so Back returns to where
        /// this started (RN `router.replace('/space/<id>')`).
        case openSpace(id: String)
    }

    /// One quick-add preset as its tile shows it (RN `PresetTile`).
    public struct PresetTile: Sendable, Hashable, Identifiable {
        public let preset: SpacePalette.Preset
        /// A space with this name exists already: "Already added", not pressable.
        public let isTaken: Bool
        /// This preset is being created (a spinner after 150 ms).
        public let isBusy: Bool
        /// Not pressable: taken, or any save runs.
        public let isDisabled: Bool
        /// Only a wait dims the others; a taken tile stays readable.
        public let isDimmed: Bool

        public var id: String { preset.name }

        /// "Garage. Creates the space straight away." or "Garage. Already added."
        public var accessibilityLabel: String {
            isTaken ? L10n.SpaceForm.presetAddedA11y(name: preset.name) : L10n.SpaceForm.presetA11y(name: preset.name)
        }

        /// RN testID `space-preset-<name lower-cased>`.
        public var identifier: String { "space-preset-\(preset.name.jsLowercased())" }
    }

    /// The form as it opens (RN `DEFAULTS`): no name, the sofa, blue.
    public static let defaults = SpaceFormValues(name: "", icon: SpacePalette.icons[0], color: SpacePalette.colors[0])

    /// What the fields hold.
    public private(set) var values = SpaceNewModel.defaults
    /// "Give the space a name." under the name.
    public private(set) var nameError: String?
    /// The last create that did not happen, shown as the notice.
    public private(set) var failure: PlacesSaveFailure?
    public private(set) var saving: Saving?
    /// Goes up each time the name field should take focus (a blank name on Create).
    public private(set) var nameFocusRequests = 0

    /// The existing spaces (key `spaces`), so presets already added say so. While it loads or
    /// after it fails, every preset stays available.
    public let existing: InventoryQuery<[SpaceWithCounts]>
    /// Asks before typing is thrown away; the view keeps ``DirtyGuard/revoked`` current.
    public let dirtyGuard: DirtyGuard

    @ObservationIgnored private let request: RouteRequest<NewSpaceResult>?
    @ObservationIgnored private let routeResults: RouteResults?
    @ObservationIgnored private let spaces: any SpacesRepository
    @ObservationIgnored private let invalidator: any InventoryInvalidating
    @ObservationIgnored private let toasts: any ToastPresenting
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let telemetry: TelemetryReporter
    @ObservationIgnored private let isFocused: @MainActor () -> Bool
    @ObservationIgnored private let navigate: @MainActor (Navigation) -> Void

    /// - Parameters:
    ///   - request: the opener's request, answered with a ``NewSpaceResult`` through `routeResults`.
    ///   - revision: the global revision now.
    ///   - isFocused: whether the sheet is still in front (RN `navigation.isFocused()`).
    public init(
        request: RouteRequest<NewSpaceResult>?,
        routeResults: RouteResults?,
        spaces: any SpacesRepository,
        revision: Int = 0,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        confirm: any ConfirmPresenting,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        isFocused: @escaping @MainActor () -> Bool,
        navigate: @escaping @MainActor (Navigation) -> Void
    ) {
        self.request = request
        self.routeResults = routeResults
        self.spaces = spaces
        self.invalidator = invalidator
        self.toasts = toasts
        self.haptics = haptics
        self.telemetry = telemetry
        self.isFocused = isFocused
        self.navigate = navigate
        existing = InventoryQuery(key: PlacesReads.spacesKey, revision: revision, read: PlacesReads.spacesWithCounts(spaces))
        dirtyGuard = DirtyGuard(confirm: confirm)
    }

    // MARK: Outputs

    /// The names already used (RN `takenSpaceNames(existing.data ?? [])`).
    public var taken: TakenSpaceNames {
        SpaceSetup.takenSpaceNames(existing.data ?? [])
    }

    /// Garage, Wardrobe, Loft and Cellar as their tiles show them.
    public var presets: [PresetTile] {
        let taken = taken
        return SpacePalette.presets.map { preset in
            let isTaken = SpaceSetup.isNameTaken(preset.name, taken: taken)
            let isBusy = saving == .preset(preset.name)
            return PresetTile(
                preset: preset,
                isTaken: isTaken,
                isBusy: isBusy,
                isDisabled: isTaken || saving != nil,
                isDimmed: saving != nil && !isBusy && !isTaken
            )
        }
    }

    /// Create space shows its spinner (only for the form's own save).
    public var isCreatingCustom: Bool { saving == .custom }

    /// Create space is off while a preset saves.
    public var isCreateDisabled: Bool { saving != nil && saving != .custom }

    /// The failed create's banner.
    public var notice: SaveNoticeCopy? { failure?.notice(subject: .space) }

    // MARK: Inputs

    /// The fields changed (RN `change`): a new name clears its error, and any change clears the
    /// failure.
    public func change(_ next: SpaceFormValues) {
        if !EntityText.same(next.name, values.name) { nameError = nil }
        failure = nil
        values = next
        syncGuard()
    }

    /// A preset's tile: creates it at once (zero typing is the point). A taken one stays put
    /// rather than making a second Garage.
    public func pickPreset(_ preset: SpacePalette.Preset) async {
        guard !SpaceSetup.isNameTaken(preset.name, taken: taken) else { return }
        await create(SpaceFormValues(name: preset.name, icon: preset.icon, color: preset.color), source: .preset(preset.name))
    }

    /// Create space, or Return in the name (RN `createCustom`). A blank name asks for one.
    public func createCustom() async {
        guard EntityText.hasText(values.name) else {
            nameError = L10n.SpaceForm.nameRequired
            nameFocusRequests += 1
            return
        }
        await create(values, source: .custom)
    }

    public func focusChanged(_ focused: Bool, revision: Int?) {
        existing.focusChanged(focused, revision: revision)
    }

    public func revisionChanged(_ revision: Int) {
        existing.revisionChanged(revision)
    }

    // MARK: Creating

    private func create(_ input: SpaceFormValues, source: Saving) async {
        guard saving == nil else { return }
        saving = source
        failure = nil
        syncGuard()
        let name = input.name.jsTrimmed()
        do {
            let created = try await spaces.create(CreateSpaceInput(name: name, icon: input.icon, color: input.color))
            telemetry.event("space_created")
            invalidator.invalidate()
            haptics(.success)
            guard isFocused() else {
                // The header Cancel closed the sheet mid-save. Navigating now would act on
                // whatever is in front, and a picker that waited was already told nothing came of
                // it (the router abandoned the request). The space is made; the list refreshes.
                toasts.show(ToastOptions(message: L10n.SpaceForm.created(name: created.name)))
                return
            }
            // Delivered and closed in the same step: the opener resumes after the sheet is gone.
            if routeResults?.deliver(request, NewSpaceResult(created)) == true {
                navigate(.close)
            } else {
                navigate(.openSpace(id: created.id))
            }
        } catch {
            saving = nil
            syncGuard()
            haptics(.error)
            if isFocused() {
                failure = PlacesSaveFailure(cause: error)
            } else {
                toasts.show(ToastOptions(message: L10n.SpaceForm.notCreated(name: name, offline: isOffline(error)), tone: .error))
            }
        }
    }

    private func syncGuard() {
        dirtyGuard.dirty = SpaceSetup.spaceValuesChanged(values, initial: Self.defaults)
        dirtyGuard.saving = saving != nil
    }
}
