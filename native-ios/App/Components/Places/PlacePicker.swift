import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The one place picker: moving and filing an item, choosing where a new item goes, binding a
/// label and opening a container by its code (RN `PlacePicker`, 07 §4.1).
///
/// Containers are grouped under their spaces in the Spaces tab's order, recent places first.
/// The filter (a stock search field in the navigation bar) matches names, label codes with or
/// without the hyphen, spaces and types, so "drw7k" finds DRW-7K2M. The sections are
/// `PlacePickerRules.sections`; this view only draws them. Reading the lists, opening the
/// container and space forms and saving the pick are the screen's: "New container in …" and
/// "New space…" come back as callbacks. Present it inside a `NavigationStack`.
struct PlacePicker<Notice: View>: View {
    let mode: PlacePickerMode
    /// Every container joined with its space (`joinPlaceOptions`); nil before the first read.
    let options: [PlaceOption]?
    /// `spaces.listWithCounts()`; nil before the first read.
    let spaces: [SpaceWithCounts]?
    /// The held recent places (`RecentPlacesModel.ids`).
    let recentIds: [String]
    /// Either list is loading with nothing to show yet: a skeleton.
    var isLoading = false
    /// Why the lists could not be read (containers without data, or spaces without data).
    var failure: (any Error)?
    var onRetry: () -> Void = {}
    /// Move and file: the item's container, shown as "Here now" and not pickable.
    var currentContainerId: String?
    /// Choose: the current choice, checked (the drop zone when nil).
    var selectedContainerId: String?
    /// Choose: "Drop zone · Sort it later" first.
    var showsDropZone = false
    /// "New container in …" under each space; everywhere but `open` by default.
    var allowsNewContainer: Bool?
    /// Focus the filter on arrival; only in `open` by default.
    var autoFocusesFilter: Bool?
    var placeholder: String = L10n.Picker.filter
    /// What the filter holds on arrival (the gallery and tests; screens start empty).
    var initialQuery = ""
    /// The row showing a spinner while the pick saves (the drop zone's is its container id); the
    /// list is locked meanwhile.
    var busyId: String?
    @ViewBuilder var notice: Notice
    let onPick: (PickedPlace) -> Void
    var onNewContainer: (_ spaceId: String, _ spaceName: String) -> Void = { _, _ in }
    /// No spaces at all: make one.
    var onNewSpace: () -> Void = {}

    @Environment(\.haptics) private var haptics
    @State private var query = ""
    @State private var arrived = false
    @FocusState private var filterFocused: Bool

    private var allowNew: Bool { allowsNewContainer ?? mode.allowsNewContainerByDefault }
    private var locked: Bool { busyId != nil }

    var body: some View {
        // One container, so the search field and the arrival focus survive the switch from the
        // skeleton to the list.
        ZStack {
            if isLoading {
                ScrollView {
                    SkeletonView(variant: .options).padding()
                }
            } else if let failure {
                ErrorStateView(cause: failure, onRetry: onRetry)
            } else {
                list
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(verbatim: placeholder))
        .searchFocused($filterFocused)
        .textInputAutocapitalization(mode == .open ? .characters : .never)
        .autocorrectionDisabled()
        .onAppear {
            // On arrival only (RN `autoFocus`), not each time a pushed form comes back.
            guard !arrived else { return }
            arrived = true
            if query.isEmpty && !initialQuery.isEmpty { query = initialQuery }
            if autoFocusesFilter ?? mode.autoFocusesFilter { filterFocused = true }
        }
    }

    private var list: some View {
        let options = options ?? []
        let sections = PlacePickerRules.sections(
            mode: mode,
            query: query,
            options: options,
            spaces: spaces ?? [],
            recentIds: recentIds,
            showDropZone: showsDropZone,
            allowNewContainer: allowNew
        )
        let noMatch = PlacePickerRules.noMatchMessage(query: query, options: options, sections: sections)
        let nothingAtAll = PlacePickerRules.isNothingAtAll(loading: isLoading, options: options, spaces: spaces, allowNewContainer: allowNew)
        return List {
            if !(Notice.self == EmptyView.self) {
                Section {
                    notice
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            if let noMatch {
                Section {
                    Text(verbatim: noMatch)
                        .textRole(.meta)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        row(entry)
                    }
                } header: {
                    header(section)
                }
            }
            if nothingAtAll {
                Section {
                    EmptyStateView(
                        title: L10n.Picker.None.title,
                        message: L10n.Picker.None.body,
                        glyph: .box,
                        primary: StateAction(label: L10n.Picker.None.action, identifier: "move-no-containers") {
                            guard !locked else { return }
                            onNewSpace()
                        }
                    )
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.immediately)
        .opacity(locked ? 0.6 : 1)
        .allowsHitTesting(!locked)
    }

    @ViewBuilder
    private func header(_ section: PlacePickerSection) -> some View {
        if section.kind != .top, let title = section.title {
            HStack(spacing: 8) {
                Group {
                    switch section.kind {
                    case .recent: Image(glyph: .clock)
                    case .new: Image(glyph: .plus)
                    default: SpacePip(color: section.color, size: 12)
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                Text(verbatim: title)
                    .lineLimit(2)
            }
            // One heading element: the title, never the clock or plus beside it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func row(_ entry: PlacePickerEntry) -> some View {
        switch entry {
        case .dropZone:
            dropZoneRow
        case .newContainer(let spaceId, let spaceName, let color):
            newContainerRow(spaceId: spaceId, spaceName: spaceName, color: color)
        case .option(let option, let recent):
            optionRow(option, recent: recent)
        }
    }

    private var dropZoneRow: some View {
        let selected = PlacePickerRules.isDropZoneSelected(selectedContainerId: selectedContainerId)
        let busy = busyId == DropZone.containerId
        return ListRow(
            action: { pick(.dropZone) },
            isSelected: selected,
            isDisabled: locked && !busy,
            accessibilityLabel: "\(L10n.Picker.dropZone), \(L10n.Picker.sortLater)",
            identifier: "place-drop-zone"
        ) {
            TypeTile(type: .other, size: 40, glyph: .inbox)
        } content: {
            Text(verbatim: L10n.Picker.dropZone).textRole(.name)
            Text(verbatim: L10n.Picker.sortLater).textRole(.meta).foregroundStyle(.secondary)
        } aside: {
            if busy {
                ProgressView()
            } else if selected {
                checkmark
            }
        }
    }

    private func newContainerRow(spaceId: String, spaceName: String, color: String?) -> some View {
        let label = L10n.Picker.newContainerIn(space: spaceName)
        return ListRow(
            action: {
                guard !locked else { return }
                onNewContainer(spaceId, spaceName)
            },
            isDisabled: locked,
            accessibilityLabel: label,
            identifier: "place-new-container-\(spaceId)"
        ) {
            Group {
                if let color {
                    SpacePip(color: color, size: 12)
                } else {
                    Image(glyph: .plus).font(.title3).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 40, height: 40)
        } content: {
            Text(verbatim: label)
                .textRole(.name)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func optionRow(_ option: PlaceOption, recent: Bool) -> some View {
        let hereNow = PlacePickerRules.isHereNow(option, mode: mode, currentContainerId: currentContainerId)
        let selected = PlacePickerRules.isSelected(option, mode: mode, selectedContainerId: selectedContainerId)
        let busy = busyId == option.id
        return ListRow(
            action: { pick(.container(option)) },
            isSelected: selected,
            isDisabled: hereNow || (locked && !busy),
            accessibilityLabel: PlacePickerRules.optionAccessibilityLabel(option, mode: mode, currentContainerId: currentContainerId),
            identifier: recent ? "place-recent-\(option.id)" : "move-to-\(option.id)"
        ) {
            TypeTile(type: option.visualType, size: 40)
        } content: {
            if let name = option.name {
                Text(verbatim: name)
                    .textRole(.name)
                    .foregroundStyle(hereNow ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: PlacePickerRules.unnamedLabel(option))
                    .textRole(.name)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if recent {
                Text(verbatim: option.spaceName).textRole(.caption).foregroundStyle(.secondary)
            }
            if hereNow {
                Text(verbatim: L10n.Picker.hereNow).textRole(.caption).foregroundStyle(.secondary)
            }
        } aside: {
            if busy {
                ProgressView()
            } else {
                HStack(spacing: 8) {
                    Tape(code: option.shortCode)
                    if selected { checkmark }
                }
            }
        }
    }

    private var checkmark: some View {
        Image(glyph: .check)
            .font(.body.weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
    }

    private func pick(_ place: PickedPlace) {
        // Locked while a pick saves; VoiceOver can still activate a row.
        guard !locked else { return }
        haptics(.choice)
        onPick(place)
    }
}

extension PlacePicker where Notice == EmptyView {
    init(
        mode: PlacePickerMode,
        options: [PlaceOption]?,
        spaces: [SpaceWithCounts]?,
        recentIds: [String],
        isLoading: Bool = false,
        failure: (any Error)? = nil,
        onRetry: @escaping () -> Void = {},
        currentContainerId: String? = nil,
        selectedContainerId: String? = nil,
        showsDropZone: Bool = false,
        allowsNewContainer: Bool? = nil,
        autoFocusesFilter: Bool? = nil,
        placeholder: String = L10n.Picker.filter,
        initialQuery: String = "",
        busyId: String? = nil,
        onPick: @escaping (PickedPlace) -> Void,
        onNewContainer: @escaping (_ spaceId: String, _ spaceName: String) -> Void = { _, _ in },
        onNewSpace: @escaping () -> Void = {}
    ) {
        self.init(
            mode: mode, options: options, spaces: spaces, recentIds: recentIds, isLoading: isLoading, failure: failure,
            onRetry: onRetry, currentContainerId: currentContainerId, selectedContainerId: selectedContainerId,
            showsDropZone: showsDropZone, allowsNewContainer: allowsNewContainer, autoFocusesFilter: autoFocusesFilter,
            placeholder: placeholder, initialQuery: initialQuery, busyId: busyId, notice: { EmptyView() }, onPick: onPick,
            onNewContainer: onNewContainer, onNewSpace: onNewSpace
        )
    }
}

#if DEBUG
#Preview("Choose") {
    NavigationStack {
        PlacePicker(
            mode: .choose,
            options: ComponentsFixtures.options,
            spaces: ComponentsFixtures.spaces,
            recentIds: ["c-drawer"],
            selectedContainerId: "c-drawer",
            showsDropZone: true,
            onPick: { _ in }
        )
        .navigationTitle(Text(verbatim: "Where it goes"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Move, busy, with a notice") {
    NavigationStack {
        PlacePicker(mode: .move, options: ComponentsFixtures.options, spaces: ComponentsFixtures.spaces, recentIds: [], currentContainerId: "c-chest", busyId: "c-bin") {
            BannerView(tone: .warning, title: "Moved meanwhile", message: "Pick again?", live: .off)
        } onPick: { _ in }
    }
}

#Preview("Nothing at all") {
    NavigationStack {
        PlacePicker(mode: .file, options: [], spaces: [], recentIds: [], onPick: { _ in })
    }
}

#Preview("Loading") {
    NavigationStack {
        PlacePicker(mode: .bind, options: nil, spaces: nil, recentIds: [], isLoading: true, onPick: { _ in })
    }
}
#endif
