import InventoryCore
import InventoryStrings

// RN: src/ui/components/PlacePicker.tsx:38-288. The one place picker's data: which sections and
// rows it shows for what was typed, and what a container made from it looks like (07 §4.1).
// Rendering, the filter field and the forms it opens are the view's.

/// What the picker is for (RN `PlacePickerProps.mode`).
public enum PlacePickerMode: Sendable, Hashable {
    /// Moving an item: its container is "Here now" and cannot be picked.
    case move
    /// Filing an item out of the drop zone: as `move`.
    case file
    /// Where a new item goes; the current choice is selected.
    case choose
    /// Which container a new label belongs to.
    case bind
    /// Opening a container by typing its label code.
    case open

    /// "New container in …" is offered by default everywhere but `open`.
    public var allowsNewContainerByDefault: Bool { self != .open }

    /// The filter is focused on arrival only in `open`, where typing the code is the point.
    public var autoFocusesFilter: Bool { self == .open }

    /// The current container is "Here now" (shown, not pickable).
    public var marksHereNow: Bool { self == .move || self == .file }
}

/// What the person picked (RN `PickedPlace`).
public enum PickedPlace: Sendable, Hashable {
    case dropZone
    case container(PlaceOption)
}

/// One row of the picker (RN `Entry`).
public enum PlacePickerEntry: Sendable, Hashable, Identifiable {
    /// A container; `recent` rows carry the space name as a caption.
    case option(PlaceOption, recent: Bool)
    /// "Drop zone · Sort it later".
    case dropZone
    /// "New container in <space>…"; `color` is set in the single "Make a new container" list,
    /// where the space pip leads the row.
    case newContainer(spaceId: String, spaceName: String, color: String?)

    /// The row's key (RN `entryKey`, PlacePicker.tsx:384-388): a container listed both under
    /// Recent and under its space gets a different key in each.
    public var id: String {
        switch self {
        case .option(let option, let recent): "\(recent ? "recent" : "space")-\(option.id)"
        case .dropZone: DropZone.containerId
        case .newContainer(let spaceId, _, _): "new-\(spaceId)"
        }
    }
}

/// One section of the picker (RN `PickerSection`).
public struct PlacePickerSection: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// The drop zone on its own, with no header.
        case top
        /// `L10n.Picker.recent`, with a clock glyph.
        case recent
        /// A space: its name and pip.
        case space
        /// `L10n.Picker.newContainerTitle`: nothing matched; make one in any space.
        case new
    }

    /// `top`, `recent`, `new`, or the space id.
    public var id: String
    public var kind: Kind
    public var title: String?
    /// The space colour, for its pip.
    public var color: String?
    public var entries: [PlacePickerEntry]

    /// Whether any row is a container.
    public var hasOption: Bool {
        entries.contains { if case .option = $0 { true } else { false } }
    }
}

/// The picker's rules (RN `PlacePicker`'s logic). Not named `PlacePicker`, which is the name
/// the SwiftUI view porting the RN component takes.
public enum PlacePickerRules {
    /// Recent places shown above the spaces (RN `MAX_RECENT_SHOWN`).
    public static let maxRecentShown = 4

    /// The sections for what was typed (RN `sections`, PlacePicker.tsx:139-205).
    ///
    /// - Parameters:
    ///   - options: every container joined with its space (`joinPlaceOptions` of
    ///     `containers.listAllWithSpace()` and `spaces.listWithCounts()`), in that order.
    ///   - spaces: `spaces.listWithCounts()`, which gives the order of the space sections; a
    ///     space only known from a container (just made) still shows, after them.
    ///   - recentIds: the held recent places (``RecentPlacesModel/ids``).
    public static func sections(
        mode: PlacePickerMode,
        query: String,
        options: [PlaceOption],
        spaces: [SpaceWithCounts],
        recentIds: [String],
        showDropZone: Bool = false,
        allowNewContainer: Bool? = nil
    ) -> [PlacePickerSection] {
        let allowNew = allowNewContainer ?? mode.allowsNewContainerByDefault
        let filtering = isFiltering(query)
        let terms = placeTerms(query)
        let matching = filtering ? options.filter { matchesPlace($0, terms: terms) } : options
        var result: [PlacePickerSection] = []

        if !filtering && mode == .choose && showDropZone {
            result.append(PlacePickerSection(id: "top", kind: .top, title: nil, color: nil, entries: [.dropZone]))
        }

        if !filtering {
            var byId: [String: PlaceOption] = [:]
            for option in options { byId[option.id] = option }  // `new Map`: a later duplicate wins
            let recent = recentIds.compactMap { byId[$0] }.prefix(maxRecentShown)
            if !recent.isEmpty {
                result.append(
                    PlacePickerSection(
                        id: "recent",
                        kind: .recent,
                        title: L10n.Picker.recent,
                        color: nil,
                        entries: recent.map { .option($0, recent: true) }
                    )
                )
            }
        }

        // Spaces in the Spaces tab's order; containers whose space is not in the list (yet)
        // still show, under their own space name.
        var order: [(id: String, name: String, color: String)] = spaces.map { ($0.id, $0.name, $0.color) }
        for option in options where !order.contains(where: { EntityText.same($0.id, option.spaceId) }) {
            order.append((option.spaceId, option.spaceName, option.spaceColor))
        }

        // Nothing matches: one list of the spaces to make it in.
        if filtering && matching.isEmpty {
            if allowNew && !order.isEmpty {
                result.append(
                    PlacePickerSection(
                        id: "new",
                        kind: .new,
                        title: L10n.Picker.newContainerTitle,
                        color: nil,
                        entries: order.map { .newContainer(spaceId: $0.id, spaceName: $0.name, color: $0.color) }
                    )
                )
            }
            return result
        }

        for space in order {
            let inSpace = matching
                .filter { EntityText.same($0.spaceId, space.id) }
                .entityStableSorted { EntityText.localeCompareBase(sortLabel($0), sortLabel($1)) }
            let offerNew = allowNew && (!filtering || !inSpace.isEmpty)
            if inSpace.isEmpty && !offerNew { continue }
            var entries: [PlacePickerEntry] = inSpace.map { .option($0, recent: false) }
            if offerNew { entries.append(.newContainer(spaceId: space.id, spaceName: space.name, color: nil)) }
            result.append(PlacePickerSection(id: space.id, kind: .space, title: space.name, color: space.color, entries: entries))
        }
        return result
    }

    /// Whether the filter holds anything but white space.
    public static func isFiltering(_ query: String) -> Bool {
        EntityText.hasText(query)
    }

    /// "Nothing matches “q”" when filtering finds no container although there are some
    /// (RN PlacePicker.tsx:310-314); nil otherwise.
    public static func noMatchMessage(query: String, options: [PlaceOption], sections: [PlacePickerSection]) -> String? {
        guard isFiltering(query), !options.isEmpty, !sections.contains(where: \.hasOption) else { return nil }
        return L10n.Picker.noMatch(query: query.jsTrimmed())
    }

    /// No containers to offer and none can be made: the "make a space" empty state
    /// (RN `nothingAtAll`, :287-288).
    public static func isNothingAtAll(loading: Bool, options: [PlaceOption], spaces: [SpaceWithCounts]?, allowNewContainer: Bool) -> Bool {
        !loading && options.isEmpty && (!allowNewContainer || (spaces ?? []).isEmpty)
    }

    /// A row's visible label: the name, or "Unnamed box" (RN `optionLabel`).
    public static func optionLabel(_ option: PlaceOption) -> String {
        option.name ?? unnamedLabel(option)
    }

    /// "Unnamed box" … "Unnamed container" for the option's type (RN `unnamedLabel`).
    public static func unnamedLabel(_ option: PlaceOption) -> String {
        L10n.Entities.unnamedContainer(
            typeName: L10n.Entities.TypeNames[option.visualType.rawValue] ?? L10n.Entities.TypeNames.other)
    }

    /// Whether the option is the item's own container in move or file mode.
    public static func isHereNow(_ option: PlaceOption, mode: PlacePickerMode, currentContainerId: String?) -> Bool {
        guard mode.marksHereNow, let currentContainerId else { return false }
        return EntityText.same(option.id, currentContainerId)
    }

    /// Whether the option shows the checkmark: the current choice in `choose` mode.
    public static func isSelected(_ option: PlaceOption, mode: PlacePickerMode, selectedContainerId: String?) -> Bool {
        guard mode == .choose, let selectedContainerId else { return false }
        return EntityText.same(option.id, selectedContainerId)
    }

    /// Whether the drop-zone row shows the checkmark: nothing else is chosen, or it is.
    public static func isDropZoneSelected(selectedContainerId: String?) -> Bool {
        selectedContainerId.map { EntityText.same($0, DropZone.containerId) } ?? true
    }

    /// What VoiceOver reads for a container row (RN :516-523).
    public static func optionAccessibilityLabel(_ option: PlaceOption, mode: PlacePickerMode, currentContainerId: String?) -> String {
        let label = optionLabel(option)
        if isHereNow(option, mode: mode, currentContainerId: currentContainerId) {
            return L10n.Picker.hereNowA11y(label: label)
        }
        return L10n.Picker.optionA11y(label: label, space: option.spaceName, spelled: spellCode(option.shortCode))
    }

    /// The container a "New container in …" form made, as the picker picks it without reading
    /// it back (RN `newContainer`, :225-248). The space may not be in the list yet (just made
    /// from here): then the space name the row showed is used, with no colour or icon.
    public static func option(for created: NewContainerResult, spaces: [SpaceWithCounts]?, spaceName: String) -> PlaceOption {
        let home = spaces?.first { EntityText.same($0.id, created.spaceId) }
        let row = ContainerWithSpace(
            container: Container(
                id: created.containerId,
                spaceId: created.spaceId,
                name: created.name,
                visualType: created.visualType,
                shortCode: created.shortCode,
                createdAt: 0,
                updatedAt: 0
            ),
            spaceName: home?.name ?? spaceName,
            itemCount: 0
        )
        return toPlaceOption(row, space: home?.space)
    }

    /// The label the in-space sort compares: the name, or the code (RN `byLabel`).
    private static func sortLabel(_ option: PlaceOption) -> String {
        option.name ?? option.shortCode
    }
}
