#if DEBUG
import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// Debug-only gallery of the shared components (see DebugGallery): every component in its main
/// states, one page per launch: `-gallery components -galleryPage N`. Long pages scroll to a
/// section with `-galleryAnchor <id>` (the ids are the section titles below, lower-cased).
struct ComponentsGallery: View {
    let page: Int

    var body: some View {
        let current = ComponentsGalleryPage(rawValue: page) ?? .tokens
        NavigationStack {
            current.content
                .navigationTitle(Text(verbatim: "\(current.rawValue). \(current.title)"))
                .navigationBarTitleDisplayMode(.inline)
        }
        .measuresLayoutWindowWidth()
    }
}

/// The gallery's pages, by number.
enum ComponentsGalleryPage: Int, CaseIterable {
    case tokens, itemRowsChip, itemRowsOther, placeRows, whereCard, quantity, banners, buttons
    case states, inputs, pickers, placePickerChoose, placePickerMove, placePickerStates, spaceForm, itemDetails, thumbs

    var title: String {
        switch self {
        case .tokens: "Tokens"
        case .itemRowsChip: "Item rows: chip"
        case .itemRowsOther: "Item rows: tools"
        case .placeRows: "Place rows"
        case .whereCard: "Where card"
        case .quantity: "Quantity"
        case .banners: "Banners"
        case .buttons: "Buttons"
        case .states: "Empty and error"
        case .inputs: "Inputs"
        case .pickers: "Pickers"
        case .placePickerChoose: "Place picker: choose"
        case .placePickerMove: "Place picker: move"
        case .placePickerStates: "Place picker: states"
        case .spaceForm: "Space form"
        case .itemDetails: "Item details"
        case .thumbs: "Thumbs"
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .tokens: GalleryTokensPage()
        case .itemRowsChip: GalleryItemRowsChipPage()
        case .itemRowsOther: GalleryItemRowsOtherPage()
        case .placeRows: GalleryPlaceRowsPage()
        case .whereCard: GalleryWhereCardPage()
        case .quantity: GalleryQuantityPage()
        case .banners: GalleryBannersPage()
        case .buttons: GalleryButtonsPage()
        case .states: GalleryStatesPage()
        case .inputs: GalleryInputsPage()
        case .pickers: GalleryPickersPage()
        case .placePickerChoose: GalleryPlacePickerChoosePage()
        case .placePickerMove: GalleryPlacePickerMovePage()
        case .placePickerStates: GalleryPlacePickerStatesPage()
        case .spaceForm: GallerySpaceFormPage()
        case .itemDetails: GalleryItemDetailsPage()
        case .thumbs: GalleryThumbsPage()
        }
    }
}

/// Scrolls a gallery list to `-galleryAnchor` on appear.
private struct GalleryAnchored<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            content.onAppear {
                if let anchor = UserDefaults.standard.string(forKey: "galleryAnchor") {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
        }
    }
}

private func galleryHeader(_ title: String) -> some View {
    Text(verbatim: title).id(title.lowercased())
}

// MARK: Pages

private struct GalleryTokensPage: View {
    var body: some View {
        GalleryAnchored {
            List {
                Section { WrappingHStack(horizontalSpacing: 12, verticalSpacing: 12) {
                    Tape(code: "DRW-7K2M")
                    Tape(code: "DRW-7K2M", size: .medium, spoken: true)
                    Tape(code: "CAB-J92R", size: .large)
                    Tape(code: "3", size: .badge)
                } } header: { galleryHeader("Tape") }
                Section { HStack(spacing: 24) { BrandMark(); BrandMark(size: .large) } } header: { galleryHeader("Mark") }
                Section {
                    HStack(spacing: 10) {
                        SpaceTile(icon: "🚗", color: "#5B8DEF", size: 32)
                        SpaceTile(icon: "🧰", color: "#2E9E4F", size: 48)
                        SpaceTile(icon: "🛋\u{FE0F}", color: "#E4572E", size: 56)
                        SpaceTile(icon: "", color: "#E0A800", size: 64)
                        SpaceTile(icon: "cube", color: "junk", size: 48)
                    }
                    WrappingHStack(horizontalSpacing: 10, verticalSpacing: 10) {
                        ForEach(ContainerVisualType.allKnown, id: \.self) { TypeTile(type: $0, size: 40) }
                    }
                    // Plain emoji, to tell a simulator without colour emoji from a tile bug.
                    Text(verbatim: "Emoji: 🚗 🧰 🛋\u{FE0F} 📥")
                    HStack(spacing: 12) {
                        ForEach(SpacePalette.colors + ["#FFFFFF", "#000000"], id: \.self) { SpacePip(color: $0) }
                    }
                } header: { galleryHeader("Tiles and pips") }
                Section {
                    HighlightedText(text: "Spare batteries AA", terms: ["batt", "aa"]).textRole(.name)
                } header: { galleryHeader("Highlight") }
                Section {
                    WrappingHStack(horizontalSpacing: 14, verticalSpacing: 12) {
                        ForEach(Glyph.allCases, id: \.self) { glyph in
                            Image(glyph: glyph).font(.title3).frame(width: 28, height: 28)
                        }
                    }
                } header: { galleryHeader("Glyphs") }
            }
        }
    }
}

private struct GalleryItemRowsChipPage: View {
    @State private var expanded: String? = ComponentsFixtures.screws.id
    @State private var models: [String: SavedQuantityModel] = [
        ComponentsFixtures.drill.id: ComponentsFixtures.quantityModel(for: ComponentsFixtures.drill),
        ComponentsFixtures.screws.id: ComponentsFixtures.quantityModel(for: ComponentsFixtures.screws),
        ComponentsFixtures.batteries.id: ComponentsFixtures.quantityModel(for: ComponentsFixtures.batteries),
        ComponentsFixtures.unnamed.id: ComponentsFixtures.quantityModel(for: ComponentsFixtures.unnamed),
    ]

    var body: some View {
        GalleryAnchored {
            List {
                Section {
                    ForEach([ComponentsFixtures.drill, ComponentsFixtures.screws, ComponentsFixtures.batteries, ComponentsFixtures.unnamed]) { item in
                        if let model = models[item.id] {
                            ItemRow(
                                item: item,
                                tool: .chip(model, isExpanded: expanded == item.id, onToggle: { expanded = expanded == item.id ? nil : item.id }),
                                terms: item.id == ComponentsFixtures.batteries.id ? ["batt"] : [],
                                onPress: {}
                            )
                        }
                    }
                } header: { galleryHeader("Chip") }
                Section {
                    if let model = models[ComponentsFixtures.drill.id] {
                        ItemRow(item: ComponentsFixtures.drill, tool: .stepper(model), onPress: {})
                    }
                } header: { galleryHeader("Stepper") }
            }
        }
    }
}

private struct GalleryItemRowsOtherPage: View {
    var body: some View {
        GalleryAnchored {
            List {
                Section {
                    ItemRow(item: ComponentsFixtures.unnamed, line: .added, tool: .file({}), now: ComponentsFixtures.now, onPress: {})
                    ItemRow(item: ComponentsFixtures.waiting, line: .added, tool: .file({}), now: ComponentsFixtures.now, thumb: 76, onPress: {})
                } header: { galleryHeader("File") }
                Section {
                    ItemRow(item: ComponentsFixtures.unnamed, line: .added, tool: .delete({}), now: ComponentsFixtures.now, onPress: {})
                    ItemRow(item: ComponentsFixtures.screws, line: .detail, tool: .delete({}), onPress: {})
                } header: { galleryHeader("Delete") }
                Section {
                    ItemRow(item: ComponentsFixtures.screws, tool: .none, onPress: {})
                    ItemRow(item: ComponentsFixtures.drill, line: .detail, tool: .none, onPress: {})
                    ItemRow(item: ComponentsFixtures.batteries, line: .detail, tool: .none, terms: ["spare", "aa"], onPress: {})
                } header: { galleryHeader("None") }
            }
        }
    }
}

private struct GalleryPlaceRowsPage: View {
    var body: some View {
        let spaces = Dictionary(uniqueKeysWithValues: ComponentsFixtures.spaces.map { ($0.id, $0) })
        let containers = Dictionary(uniqueKeysWithValues: ComponentsFixtures.containers.map { ($0.id, $0) })
        GalleryAnchored {
            List {
                Section {
                    SpaceRow(space: ComponentsFixtures.spaces[0], onPress: {})
                    SpaceRow(space: ComponentsFixtures.spaces[2], onPress: {})
                } header: { galleryHeader("Spaces") }
                Section {
                    ContainerRow(container: ContainerRowData(id: "c1", name: "Tool chest", shortCode: "CAB-J92R", visualType: .cabinet, itemCount: 7, qrToken: "abc"), onPress: {})
                    ContainerRow(container: ContainerRowData(id: "c2", name: nil, shortCode: "BIN-4F2A", visualType: .bin, itemCount: 0), onPress: {})
                } header: { galleryHeader("Containers") }
                Section {
                    PlaceRow(hit: LocationSearchResult(kind: .space, id: "s-garage", title: "Garage", subtitle: "", spaceId: "s-garage", itemCount: 12), spaces: spaces, containers: containers, terms: ["gar"], onPress: {})
                    PlaceRow(hit: LocationSearchResult(kind: .container, id: "c-drawer", title: "Screws and nails", subtitle: "", spaceId: "s-garage", itemCount: 1), spaces: spaces, containers: containers, terms: ["screws"], onPress: {})
                    PlaceRow(hit: LocationSearchResult(kind: .container, id: "c-new", title: "Shoe rack", subtitle: "Container in Hall", spaceId: "s-hall", itemCount: 0), spaces: spaces, containers: containers, onPress: {})
                } header: { galleryHeader("Search") }
                Section {
                    LocationLine(place: ComponentsFixtures.filedPlace)
                    LocationLine(place: RowPlace(ComponentsFixtures.batteries))
                    LocationLine(place: ComponentsFixtures.dropZonePlace)
                    LocationLine(place: ComponentsFixtures.filedPlace, size: .inline, showsContainer: false)
                } header: { galleryHeader("Location") }
            }
        }
    }
}

private struct GalleryWhereCardPage: View {
    var body: some View {
        List {
            Section {
                WhereCard(place: ComponentsFixtures.filedPlace, name: "Cordless drill", links: .init(openSpace: {}, openContainer: {}), onMove: {})
            }
            Section {
                WhereCard(place: RowPlace(ComponentsFixtures.batteries), name: "", links: .init(openSpace: {}, openContainer: {}), onMove: {})
            }
            Section {
                WhereCard(place: ComponentsFixtures.dropZonePlace, name: "", onMove: {})
            }
        }
    }
}

private struct GalleryQuantityPage: View {
    @State private var count = 3
    @State private var compact = 0
    @State private var saved = ComponentsFixtures.quantityModel(for: ComponentsFixtures.screws)
    @State private var none = ComponentsFixtures.quantityModel(for: ComponentsFixtures.batteries)
    @State private var failing = ComponentsFixtures.quantityModel(for: ComponentsFixtures.drill, failing: true)

    var body: some View {
        GalleryAnchored {
            List {
                Section {
                    QuantityStepper(value: count, onChange: { count = $0 }, itemName: "Wood screws")
                    QuantityStepper(value: compact, onChange: { compact = $0 }, size: .compact)
                    QuantityStepper(value: 9999, onChange: { _ in }, size: .compact)
                    QuantityStepper(value: 2, onChange: { _ in }, isDisabled: true)
                } header: { galleryHeader("Stepper") }
                Section {
                    SavedQuantityStepper(model: saved, itemName: "Wood screws")
                    SavedQuantityStepper(model: none, itemName: "Spare batteries")
                    SavedQuantityStepper(model: failing, itemName: "Cordless drill")
                        .task { failing.setQuantity(2) }
                } header: { galleryHeader("Saved") }
                Section {
                    HStack {
                        QuantityChip(quantity: 1, itemName: "Drill", itemId: "a", isExpanded: false, onToggle: {})
                        QuantityChip(quantity: 120, itemName: "Screws", itemId: "b", isExpanded: true, onToggle: {})
                        QuantityChip(quantity: 0, itemName: "Batteries", itemId: "c", isExpanded: false, onToggle: {})
                    }
                } header: { galleryHeader("Chip") }
            }
        }
    }
}

private struct GalleryBannersPage: View {
    var body: some View {
        GalleryAnchored {
            List {
                Section {
                    BannerView(tone: .info, title: "Saved on this phone only", message: "Join a household to share it.", primary: BannerAction(label: "Join") {}, secondary: BannerAction(label: "Not now") {}, live: .off)
                    BannerView(tone: .warning, title: "Not saved", message: "Check the connection and try again. What you typed is still here.", primary: BannerAction(label: "Try again", isLoading: true) {}, onDismiss: {})
                    BannerView(tone: .info, message: "Showing what was last read.", live: .off, chrome: .row)
                } header: { galleryHeader("Banner") }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                Section {
                    SuggestionBannerView(state: .running)
                    SuggestionBannerView(state: .applied(confidence: 0.92, forName: "Cordless drill"))
                    SuggestionBannerView(state: .stale(forName: "Angle grinder"), onRefresh: {})
                    SuggestionBannerView(state: .failed(.offline), onRetry: {})
                    SuggestionBannerView(state: .failed(.notConfigured), onRetry: {})
                } header: { galleryHeader("Suggestion") }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
        }
    }
}

private struct GalleryButtonsPage: View {
    var body: some View {
        GalleryAnchored {
            List {
                Section {
                    SkeletonView(variant: .rows, rows: 2)
                    SkeletonView(variant: .options, rows: 3)
                } header: { galleryHeader("Skeleton") }
                .listRowBackground(Color.clear)
                Section {
                    LoadingButton(label: "Save", glyph: .check, action: {})
                    LoadingButton(label: "Saving", isLoading: true, action: {})
                    LoadingButton(label: "Move…", glyph: .move, variant: .secondary, size: .small, action: {})
                    LoadingButton(label: "Not now", variant: .quiet, action: {})
                    LoadingButton(label: "Delete space", glyph: .trash, variant: .destructive, action: {})
                    LoadingButton(label: "Disabled", isDisabled: true, action: {})
                    LoadingButton(label: "Save and add another item to this container", fullWidth: true, action: {})
                } header: { galleryHeader("Buttons") }
                Section {
                    ZStack {
                        LinearGradient(colors: [.orange, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                        VStack(spacing: 12) {
                            StatusPill(text: "3 photos taken", glyph: .layers)
                            StatusPill(text: "Into Tool chest, Garage")
                        }
                    }
                    .frame(height: 140)
                    .listRowInsets(EdgeInsets())
                } header: { galleryHeader("Status pill") }
            }
        }
    }
}

private struct GalleryStatesPage: View {
    var body: some View {
        VStack(spacing: 0) {
            EmptyStateView(
                title: L10n.Picker.None.title,
                message: L10n.Picker.None.body,
                glyph: .inbox,
                primary: StateAction(label: L10n.Picker.None.action, glyph: .plus) {},
                secondary: StateAction(label: "Add an item") {}
            )
            Divider()
            ErrorStateView(cause: nil, subject: .item, onRetry: {}, secondary: StateAction(label: L10n.Common.goToHome) {})
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct GalleryInputsPage: View {
    @State private var name = ""
    @State private var tags = "power tools"
    @State private var notes = "Bought in 2024.\nThe charger is in the kitchen drawer."
    @State private var code = "MMWKYM2H78A"
    @State private var expanded = true

    var body: some View {
        GalleryAnchored {
            Form {
                Section {
                    LabeledTextField(label: L10n.SpaceForm.nameLabel, text: $name, placeholder: L10n.SpaceForm.namePlaceholder, isRequired: true)
                    LabeledTextField(label: L10n.SpaceForm.nameLabel, text: $name, error: L10n.SpaceForm.nameRequired, isRequired: true)
                    LabeledTextField(label: L10n.Forms.tagsLabel, text: $tags, hint: L10n.Forms.tagsHint, isOptional: true, counter: "12 of 26")
                    LabeledTextField(label: L10n.Forms.notesLabel, text: $notes, isMultiline: true)
                } header: { galleryHeader("Text fields") }
                Section {
                    CodeInput(label: "Recovery code", value: $code, hint: "From the paper you kept")
                } header: { galleryHeader("Code") }
                .listRowBackground(Color.clear)
                Section {
                    NavigationLink { EmptyView() } label: {
                        SettingsRow(label: "Household", value: "Joined as Walid's iPhone", glyph: .server)
                    }
                    NavigationLink { EmptyView() } label: {
                        SettingsRow(label: "Backup", value: "Needs attention", tone: .signal, glyph: .backup)
                    }
                    SettingsRow(label: "Version", value: "0.2.0", glyph: .phone)
                    DisclosureGroup(isExpanded: $expanded) {
                        SettingsRow(label: "Schema", value: "v7")
                    } label: {
                        SettingsRow(label: "Technical details", glyph: .settings)
                    }
                    FactRow(label: L10n.Forms.categoryLabel, text: "Tools")
                } header: { galleryHeader("Settings") }
            }
        }
    }
}

private struct GalleryPickersPage: View {
    @State private var icon = "🛋"
    @State private var color = "#5b8def"
    @State private var type: ContainerVisualType = .drawer
    @State private var mode = "single"
    @State private var space = "s-garage"

    var body: some View {
        GalleryAnchored {
            Form {
                Section {
                    WrappingHStack(horizontalSpacing: 8, verticalSpacing: 8) {
                        TagChip(label: "power tools")
                        TagChip(label: "blue")
                        TagChip(label: "Tools") {}
                        TagChip(label: "Kitchen", isSelected: true) {}
                    }
                } header: { galleryHeader("Chips") }
                Section {
                    SegmentedChoice(
                        options: [SegmentOption(value: "single", label: "Single"), SegmentOption(value: "several", label: "Several", glyph: .layers)],
                        selection: $mode,
                        accessibilityLabel: "Mode"
                    )
                } header: { galleryHeader("Segmented") }
                Section {
                    ChoiceList(
                        options: ComponentsFixtures.spaces.map { space in
                            ChoiceOption(value: space.id, title: space.name, subtitle: PlaceRowText.spaceCounts(containers: space.containerCount, items: space.itemCount), leading: AnyView(SpaceTile(icon: space.icon, color: space.color, size: 32)))
                        },
                        selection: $space,
                        accessibilityLabel: "Space"
                    )
                } header: { galleryHeader("Choice") }
                Section { EmojiPicker(label: L10n.SpaceForm.iconLabel, value: $icon, color: color) } header: { galleryHeader("Emoji") }
                Section { SwatchPicker(label: L10n.SpaceForm.colourLabel, value: $color) } header: { galleryHeader("Swatch") }
                Section { TypeGrid(label: "Type", value: $type) } header: { galleryHeader("Type") }
            }
        }
    }
}

private struct GalleryPlacePickerChoosePage: View {
    var body: some View {
        PlacePicker(
            mode: .choose,
            options: ComponentsFixtures.options,
            spaces: ComponentsFixtures.spaces,
            recentIds: ["c-drawer", "c-shelf"],
            selectedContainerId: "c-drawer",
            showsDropZone: true,
            onPick: { _ in }
        )
    }
}

private struct GalleryPlacePickerMovePage: View {
    var body: some View {
        PlacePicker(
            mode: .move,
            options: ComponentsFixtures.options,
            spaces: ComponentsFixtures.spaces,
            recentIds: ["c-chest"],
            currentContainerId: "c-chest",
            busyId: "c-bin"
        ) {
            BannerView(tone: .warning, title: "Moved meanwhile", message: "Someone moved it to Spice shelf. Pick again?", live: .off)
        } onPick: { _ in }
    }
}

private struct GalleryPlacePickerStatesPage: View {
    private var state: String { UserDefaults.standard.string(forKey: "galleryState") ?? "nothing" }

    var body: some View {
        switch state {
        case "loading":
            PlacePicker(mode: .choose, options: nil, spaces: nil, recentIds: [], isLoading: true, onPick: { _ in })
        case "failure":
            PlacePicker(mode: .choose, options: nil, spaces: nil, recentIds: [], failure: CocoaError(.fileReadUnknown), onPick: { _ in })
        case "nomatch":
            PlacePicker(mode: .move, options: ComponentsFixtures.options, spaces: ComponentsFixtures.spaces, recentIds: [], initialQuery: "zzz", onPick: { _ in })
        case "open":
            PlacePicker(mode: .open, options: ComponentsFixtures.options, spaces: ComponentsFixtures.spaces, recentIds: [], initialQuery: "drw7k", onPick: { _ in })
        default:
            PlacePicker(mode: .choose, options: [], spaces: [], recentIds: [], onPick: { _ in })
        }
    }
}

private struct GallerySpaceFormPage: View {
    @State private var values = SpaceFormValues(name: "", icon: "🧰", color: "#2E9E4F")
    @FocusState private var focus: SpaceFieldsFocus?

    var body: some View {
        FormLayout {
            SaveNotice(copy: SaveNoticeCopy(cause: CocoaError(.fileWriteUnknown), subject: .space), action: BannerAction(label: L10n.Common.tryAgain) {})
        } content: {
            SpaceFields(values: $values, nameError: L10n.SpaceForm.nameRequired, onSubmit: {}, previewMeta: L10n.SpaceForm.previewNew, focus: $focus)
        } bottomBar: {
            LoadingButton(label: L10n.SpaceForm.create, fullWidth: true, action: {})
        }
    }
}

private struct GalleryItemDetailsPage: View {
    @State private var values = ItemFormValues(name: "Cordless drill", category: "To", tags: "", quantity: "1", notes: "")
    @FocusState private var focus: ItemDetailsField?
    private var locked: Bool { UserDefaults.standard.string(forKey: "galleryState") == "locked" }

    var body: some View {
        if locked {
            DropZoneLocked(onGoToDropZone: {})
        } else {
            Form {
                Section {
                    ItemDetailsFields(values: $values, suggestions: ["Tools", "Toys", "Towels"], focus: $focus)
                }
            }
            .onAppear { focus = .category }
        }
    }
}

private struct GalleryThumbsPage: View {
    @Environment(\.photoPathResolver) private var resolver

    var body: some View {
        let photo = ComponentsFixtures.samplePhotoURI(resolver: resolver)
        List {
            Section {
                HStack(spacing: 12) {
                    Thumb(uri: nil, size: 40)
                    Thumb(uri: nil, size: 48)
                    Thumb(uri: "file:///nowhere/item-photos/missing.webp", size: 56)
                    Thumb(uri: nil, size: 76)
                }
            } header: { galleryHeader("Placeholder") }
            Section {
                HStack(spacing: 12) {
                    Thumb(uri: photo, size: 40)
                    Thumb(uri: photo, size: 48)
                    Thumb(uri: photo, size: 56)
                    Thumb(uri: photo, size: 76)
                    Thumb(uri: photo, size: 88, action: {}, accessibilityLabel: "Photo of the sample")
                }
            } header: { galleryHeader("Photo") }
            Section {
                ItemRow(item: ComponentsFixtures.item(id: "photo", name: "Sample with photo", quantity: 2, photo: photo), tool: .none, thumb: 76, onPress: {})
            } header: { galleryHeader("Row") }
        }
    }
}
#endif
