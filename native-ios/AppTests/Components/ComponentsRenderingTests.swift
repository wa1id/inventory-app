import SwiftUI
import Testing
import UIKit
import InventoryAppModels
import InventoryCore
import InventoryStrings
@testable import Inventory

/// Every shared component, drawn in light, dark and at the largest accessibility size, at a
/// phone's width: it renders, has a height, and never runs off the side.
@MainActor
@Suite("Components render")
struct ComponentsRenderingTests {
    static let width: CGFloat = 390

    /// The components in their main states, by name.
    static var samples: [(name: String, view: AnyView)] {
        let drill = ComponentsFixtures.drill
        let screws = ComponentsFixtures.screws
        let spaces = Dictionary(uniqueKeysWithValues: ComponentsFixtures.spaces.map { ($0.id, $0) })
        let containers = Dictionary(uniqueKeysWithValues: ComponentsFixtures.containers.map { ($0.id, $0) })
        return [
            ("tape", AnyView(HStack { Tape(code: "DRW-7K2M"); Tape(code: "CAB-J92R", size: .large, spoken: true) })),
            ("mark", AnyView(HStack { BrandMark(); BrandMark(size: .large) })),
            ("tiles", AnyView(HStack { SpaceTile(icon: "🚗", color: "#5B8DEF", size: 64); SpaceTile(icon: "", color: "junk"); TypeTile(type: "spaceship"); SpacePip(color: "#FFFFFF") })),
            ("item row chip", AnyView(ItemRow(item: drill, tool: .chip(ComponentsFixtures.quantityModel(for: drill), isExpanded: true, onToggle: {}), onPress: {}))),
            ("item row stepper", AnyView(ItemRow(item: screws, tool: .stepper(ComponentsFixtures.quantityModel(for: screws)), onPress: {}))),
            ("item row file", AnyView(ItemRow(item: ComponentsFixtures.waiting, line: .added, tool: .file({}), thumb: 76, onPress: {}))),
            ("item row delete", AnyView(ItemRow(item: ComponentsFixtures.unnamed, line: .added, tool: .delete({}), onPress: {}))),
            ("item row none", AnyView(ItemRow(item: ComponentsFixtures.batteries, line: .detail, tool: .none, terms: ["batt"], onPress: {}))),
            ("space row", AnyView(SpaceRow(space: ComponentsFixtures.spaces[2], onPress: {}))),
            ("container row", AnyView(ContainerRow(container: ContainerRowData(id: "c", name: nil, shortCode: "BIN-4F2A", visualType: .bin, itemCount: 2, qrToken: "t"), onPress: {}))),
            ("place row", AnyView(PlaceRow(hit: LocationSearchResult(kind: .container, id: "c-drawer", title: "", subtitle: "", spaceId: "s-garage", itemCount: 1), spaces: spaces, containers: containers, onPress: {}))),
            ("location line", AnyView(VStack { LocationLine(place: ComponentsFixtures.filedPlace); LocationLine(place: ComponentsFixtures.dropZonePlace) })),
            ("where card", AnyView(WhereCard(place: ComponentsFixtures.filedPlace, name: "Cordless drill", onMove: {}))),
            ("stepper", AnyView(QuantityStepper(value: 9999, onChange: { _ in }, error: "The quantity was not saved."))),
            ("saved stepper", AnyView(SavedQuantityStepper(model: ComponentsFixtures.quantityModel(for: ComponentsFixtures.batteries), itemName: "Batteries"))),
            ("chip", AnyView(QuantityChip(quantity: 0, itemName: "Batteries", itemId: "b", isExpanded: true, onToggle: {}))),
            ("banner", AnyView(BannerView(tone: .warning, title: "Not saved", message: "Try again.", primary: BannerAction(label: "Try again") {}, secondary: BannerAction(label: "Not now") {}, onDismiss: {}, live: .off))),
            ("suggestion", AnyView(SuggestionBannerView(state: .stale(forName: "Angle grinder"), onRefresh: {}))),
            ("empty", AnyView(EmptyStateView(title: "Nothing here", message: "Add something.", glyph: .inbox, primary: StateAction(label: "Add") {}))),
            ("error", AnyView(ErrorStateView(cause: nil, subject: .item, onRetry: {}))),
            ("buttons", AnyView(VStack { LoadingButton(label: "Save and add another", fullWidth: true, action: {}); LoadingButton(label: "Saving", isLoading: true, action: {}) })),
            ("status pill", AnyView(StatusPill(text: "3 photos taken", glyph: .layers))),
            ("code input", AnyView(CodeInput(label: "Recovery code", value: .constant("MMWKYM2H78ABCDEFGHJKMNPQRS"), hint: "From the paper"))),
            ("text field", AnyView(LabeledTextField(label: "Tags", text: .constant("power tools"), error: "Too long", isOptional: true, counter: "12 of 26", chrome: .boxed))),
            ("settings row", AnyView(SettingsRow(label: "Backup", value: "Needs attention", tone: .signal, glyph: .backup))),
            ("chips", AnyView(HStack { TagChip(label: "power tools"); TagChip(label: "Tools", isSelected: true) {} })),
            ("emoji picker", AnyView(EmojiPicker(label: "Icon", value: .constant("🛋"), color: "#5B8DEF"))),
            ("swatch picker", AnyView(SwatchPicker(label: "Colour", value: .constant("#123456")))),
            ("type grid", AnyView(TypeGrid(label: "Type", value: .constant(.drawer)))),
            ("thumb", AnyView(HStack { Thumb(uri: nil, size: 40); Thumb(uri: "file:///missing.webp", size: 88, action: {}, accessibilityLabel: "Photo") })),
            ("drop zone locked", AnyView(DropZoneLocked(onGoToDropZone: {}))),
        ]
    }

    @Test("renders within the width", arguments: ComponentsHost.Appearance.all)
    func rendersWithinWidth(appearance: ComponentsHost.Appearance) {
        for sample in Self.samples {
            let rendered = ComponentsHost.render(sample.view.padding(.horizontal, 16), width: Self.width, appearance: appearance)
            #expect(rendered.size.height > 0, "\(sample.name) has no height")
            #expect(rendered.size.width <= Self.width + 0.5, "\(sample.name) is \(rendered.size.width) pt wide")
        }
    }

    @Test("draws to an image")
    func drawsToAnImage() {
        let renderer = ImageRenderer(content: HStack { Tape(code: "DRW-7K2M"); BrandMark(); SpaceTile(icon: "🚗", color: "#5B8DEF") }.padding())
        renderer.scale = 2
        #expect(renderer.uiImage != nil)
    }
}

/// The design tokens: every glyph exists, and the stacking rule matches RN's.
@MainActor
@Suite("Components design tokens")
struct ComponentsDesignTokenTests {
    @Test("every glyph is an SF Symbol on this system", arguments: Glyph.allCases)
    func glyphExists(glyph: Glyph) {
        #expect(UIImage(systemName: glyph.systemName) != nil, "\(glyph.systemName)")
    }

    @Test("every container type has its own symbol, unknown types the tag")
    func containerSymbols() {
        let symbols = ContainerVisualType.allKnown.map { Glyph.container($0) }
        #expect(Set(symbols).count == ContainerVisualType.allKnown.count)
        #expect(Glyph.container("Box") == .other)
        #expect(Glyph.container(.other) == .other)
    }

    @Test("layouts stack at xxxLarge and up, or in a window narrower than 360 pt")
    func stackingRule() {
        #expect(!LayoutScale.isStacked(dynamicTypeSize: .xxLarge, windowWidth: 390))
        #expect(LayoutScale.isStacked(dynamicTypeSize: .xxxLarge, windowWidth: 390))
        #expect(LayoutScale.isStacked(dynamicTypeSize: .accessibility5, windowWidth: 1024))
        #expect(LayoutScale.isStacked(dynamicTypeSize: .large, windowWidth: 359))
        #expect(!LayoutScale.isStacked(dynamicTypeSize: .large, windowWidth: 360))
    }

    @Test("fixed-geometry text is capped, the rest scales")
    func typeCaps() {
        #expect(TextRole.badge.maximumSize == .xxLarge)
        #expect(TextRole.tapeS.maximumSize == .xxxLarge)
        #expect(TextRole.stepperL.maximumSize == .xxxLarge)
        #expect(TextRole.name.maximumSize == nil)
        #expect(TextRole.heading.isHeader)
        #expect(!TextRole.whereCard.isHeader)
    }

    @Test("a stored colour draws through safeColor")
    func spaceColour() {
        let junk = UIColor(Color(spaceHex: "not a colour"))
        let fallback = UIColor(Color(spaceHex: HexColor.spaceFallback))
        #expect(junk.cgColor.components == fallback.cgColor.components)
    }
}

/// What VoiceOver hears from the components, read back from the rendered views.
@MainActor
@Suite("Components accessibility")
struct ComponentsAccessibilityTests {
    @Test("an item row is one element named for the item, with its chip beside it")
    func itemRow() {
        let item = ComponentsFixtures.screws
        let model = ComponentsFixtures.quantityModel(for: item)
        let rendered = ComponentsHost.render(ItemRow(item: item, tool: .chip(model, isExpanded: false, onToggle: {}), onPress: {}))
        let row = rendered.element(identifier: ItemRowText.rowIdentifier(item.id))
        #expect(row?.label == ItemRowText.accessibilityLabel(item, quantity: item.quantity), "\(rendered.dump)")
        let chip = rendered.element(identifier: ItemRowText.chipIdentifier(item.id))
        #expect(chip?.label == ItemRowText.chipAccessibilityLabel(name: item.name, quantity: item.quantity))
        #expect(chip?.traits.contains(.button) == true)
    }

    @Test("the review's trash button names the item, or the photo when unnamed")
    func deleteButton() {
        let item = ComponentsFixtures.unnamed
        let rendered = ComponentsHost.render(ItemRow(item: item, line: .added, tool: .delete({}), onPress: {}))
        #expect(rendered.element(identifier: ItemRowText.deleteIdentifier(item.id))?.label == L10n.Rows.deletePhotoA11y)
    }

    @Test("a spoken tape spells the code; a plain one is silent")
    func tape() {
        let spoken = ComponentsHost.render(Tape(code: "DRW-7K2M", spoken: true))
        #expect(spoken.element(label: L10n.A11y.labelCode(spelled: "D R W, 7 K 2 M")) != nil)
        let silent = ComponentsHost.render(Tape(code: "DRW-7K2M"))
        #expect(silent.elements.allSatisfy { !$0.label.contains("DRW") })
    }

    @Test("the stepper is one adjustable element with the item's name and the count")
    func stepper() {
        let rendered = ComponentsHost.render(QuantityStepper(value: 0, onChange: { _ in }, itemName: "Screws"))
        let element = rendered.element(label: QuantityStepperCopy.fieldLabel(itemName: "Screws"))
        #expect(element?.value == L10n.Rows.noneLeft)
        #expect(element?.traits.contains(.adjustable) == true)
    }

    @Test("space and container rows speak their counts")
    func placeRows() {
        let space = ComponentsFixtures.spaces[0]
        let spaceRow = ComponentsHost.render(SpaceRow(space: space, onPress: {}))
        #expect(spaceRow.element(identifier: PlaceRowText.spaceIdentifier(space.id))?.label == PlaceRowText.spaceAccessibilityLabel(name: space.name, containers: space.containerCount, items: space.itemCount))
        let data = ContainerRowData(id: "c1", name: "Tool chest", shortCode: "CAB-J92R", visualType: .cabinet, itemCount: 7, qrToken: "t")
        let containerRow = ComponentsHost.render(ContainerRow(container: data, onPress: {}))
        #expect(containerRow.element(identifier: PlaceRowText.containerIdentifier("c1"))?.label == PlaceRowText.containerAccessibilityLabel(data))
    }

    @Test("swatches are read by colour name and the chosen one is selected")
    func swatches() {
        let rendered = ComponentsHost.render(SwatchPicker(label: "Colour", value: .constant("#E0A800")))
        let amber = rendered.element(identifier: "space-colour-#E0A800")
        #expect(amber?.label == "Amber")
        #expect(amber?.traits.contains(.selected) == true)
        #expect(rendered.element(identifier: "space-colour-#5B8DEF")?.traits.contains(.selected) == false)
    }

    @Test("a skeleton shows after its wait, as one element that says it is loading")
    func skeleton() async {
        let early = ComponentsHost.render(SkeletonView(variant: .rows, rows: 2), settle: 0.01)
        #expect(early.element(label: L10n.A11y.loading) == nil)
        let rendered = await ComponentsHost.renderAfter(.milliseconds(500), SkeletonView(variant: .rows, rows: 2))
        #expect(rendered.element(label: L10n.A11y.loading) != nil, "\(rendered.dump)")
    }

    @Test("a settings row speaks its value with its label")
    func settingsRow() {
        let rendered = ComponentsHost.render(SettingsRow(label: "Backup", value: "On", identifier: "settings-backup"))
        #expect(rendered.element(identifier: "settings-backup")?.label == "Backup, On")
    }
}
