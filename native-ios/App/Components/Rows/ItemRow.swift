import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// An item in any list: the name over the answer to "where is it?", the same size so the answer
/// is never the smallest thing on the row (RN `ItemRow`, 06 §15.2).
///
/// The quantity control sits beside the pressable row, never inside it. The row speaks as one
/// sentence: name, where, how many. Value-typed, so a renamed space or container redraws it.
struct ItemRow: View {
    /// The control at the end of the row (RN `tool`). The chip and stepper take the item's
    /// `SavedQuantityModel`; a screen keeps them in an `ItemRowQuantityModels`, one per item id,
    /// so a write outlives a row that scrolls away.
    enum Tool {
        /// The quantity chip at the end of the name's line; tapping it opens a large stepper
        /// under the row. The list keeps at most one row expanded.
        case chip(SavedQuantityModel, isExpanded: Bool, onToggle: () -> Void)
        /// A compact stepper that writes through, beside a 48 pt thumbnail.
        case stepper(SavedQuantityModel)
        /// "File…" (the drop zone); the count folds into the second line.
        case file(() -> Void)
        /// A trash button (the Quick Snap review); the count folds into the second line.
        case delete(() -> Void)
        /// A "×4" badge, nothing for one.
        case none

        var kind: ItemRowToolKind {
            switch self {
            case .chip: .chip
            case .stepper: .stepper
            case .file: .file
            case .delete: .delete
            case .none: .none
            }
        }

        var model: SavedQuantityModel? {
            switch self {
            case .chip(let model, _, _), .stepper(let model): model
            default: nil
            }
        }
    }

    let item: ItemWithContext
    var line: ItemRowLine = .where
    var tool: Tool = .none
    /// Search terms to mark in the name.
    var terms: [String] = []
    /// `added` rows: epoch ms "Added 5 minutes ago" counts from (a ticking clock), so the row ages.
    var now: Int64?
    /// 56, or 76 for photo-first lists.
    var thumb: CGFloat = DesignMetrics.thumb
    /// Overrides `item-row-<id>`.
    var identifier: String?
    let onPress: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chipWidth: CGFloat = DesignMetrics.minTouchTarget
    @ScaledMetric(relativeTo: .headline) private var nameLineHalf: CGFloat = 11
    private let layout = LayoutScale()

    /// The count on screen: the chip and stepper rows show the model's optimistic one.
    private var quantity: Int { tool.model?.quantity ?? item.quantity }

    var body: some View {
        content
            // Initial too: the screen keeps the models while lazy rows come and go, and a row that
            // scrolls back in must adopt what was read meanwhile (RN's hook re-read on mount).
            .onChange(of: QuantitySync(quantity: item.quantity, updatedAt: item.updatedAt), initial: true) { _, sync in
                tool.model?.itemDidChange(quantity: sync.quantity, updatedAt: sync.updatedAt)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch tool {
        case .chip(let model, let isExpanded, let onToggle):
            VStack(alignment: .leading, spacing: 8) {
                chipLine(model: model, isExpanded: isExpanded, onToggle: onToggle)
                if isExpanded {
                    expandedStepper(model: model, onToggle: onToggle)
                        .transition(.opacity)
                }
            }
        case .stepper(let model):
            RowWithTool {
                mainRow()
            } tool: {
                SavedQuantityStepper(model: model, itemName: item.name, size: .compact, identifierSuffix: item.id)
            }
        case .file(let onFile):
            RowWithTool {
                mainRow()
            } tool: {
                LoadingButton(
                    label: L10n.Rows.file,
                    glyph: .move,
                    variant: .secondary,
                    size: .small,
                    accessibilityLabel: ItemRowText.fileAccessibilityLabel(name: item.name),
                    identifier: ItemRowText.fileIdentifier(item.id),
                    action: onFile
                )
                // A 44 pt target around the small button (RN: 40 pt plus slop), so a near miss
                // files rather than opening the item.
                .frame(minHeight: DesignMetrics.minTouchTarget)
                .contentShape(Rectangle())
            }
        case .delete(let onDelete):
            RowWithTool {
                mainRow()
            } tool: {
                Button(action: onDelete) {
                    Image(glyph: .trash)
                        .font(.title3)
                        .frame(width: DesignMetrics.minTouchTarget, height: DesignMetrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .accessibilityLabel(Text(verbatim: ItemRowText.deleteAccessibilityLabel(name: item.name)))
                .accessibilityIdentifier(ItemRowText.deleteIdentifier(item.id))
            }
        case .none:
            mainRow(aside: true)
        }
    }

    /// The chip sits at the end of the name's line, so where the item is (the answer) runs the
    /// full width under it. Stacked, it drops under the text.
    @ViewBuilder
    private func chipLine(model: SavedQuantityModel, isExpanded: Bool, onToggle: @escaping () -> Void) -> some View {
        let chip = QuantityChip(quantity: model.quantity, itemName: ItemRowText.displayName(item.name), itemId: item.id, isExpanded: isExpanded) {
            toggle(onToggle)
        }
        if layout.isStacked {
            VStack(alignment: .trailing, spacing: 4) {
                mainRow()
                // The chip's line is outside the row's pressable part: a tap on the blank space
                // beside it does nothing rather than open the item.
                chip
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .absorbsListRowTaps()
            }
        } else {
            let lineHalf = nameLineHalf
            ZStack(alignment: .topTrailing) {
                mainRow(nameInset: chipWidth + 8, alignTop: true)
                chip
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipWidth = $0 }
                    // Centred on the name's first line.
                    .alignmentGuide(.top) { dimensions in dimensions.height / 2 - lineHalf }
            }
        }
    }

    private func expandedStepper(model: SavedQuantityModel, onToggle: @escaping () -> Void) -> some View {
        AdaptiveStack(horizontalAlignment: .leading, spacing: 12) {
            QuantityStepper(
                value: model.quantity,
                onChange: { model.setQuantity($0) },
                size: .large,
                itemName: SavedQuantityModel.labelName(item.name),
                error: model.error,
                identifierSuffix: item.id
            )
            LoadingButton(label: L10n.Quantity.done, variant: .quiet, size: .small) { toggle(onToggle) }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The stepper area is outside the row's pressable part, as in RN: a tap beside Done or
        // between the controls does nothing rather than open the item.
        .absorbsListRowTaps()
    }

    private func toggle(_ onToggle: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: Double(Motion.duration.expand) / 1000)) {
            onToggle()
        }
    }

    private func mainRow(aside: Bool = false, nameInset: CGFloat = 0, alignTop: Bool = false) -> some View {
        let small = layout.isStacked || tool.kind == .stepper
        let size = CGFloat(ItemRowText.thumbSize(Int(thumb), small: small))
        return ListRow(
            action: onPress,
            minHeight: size,
            alignment: alignTop ? .top : .center,
            accessibilityLabel: ItemRowText.accessibilityLabel(item, quantity: quantity),
            accessibilityHint: ItemRowText.accessibilityHint,
            identifier: identifier ?? ItemRowText.rowIdentifier(item.id)
        ) {
            Thumb(uri: item.photoThumbUri ?? item.photoUri, size: size)
        } content: {
            name.padding(.trailing, nameInset)
            secondLine
        } aside: {
            if aside, let badge = ItemRowText.badge(item.quantity) {
                Text(verbatim: badge.text)
                    .textRole(.aside)
                    .foregroundStyle(badge.isNoneLeft ? DesignColor.signal : .primary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var name: some View {
        if ItemRowText.isUnnamed(item.name) {
            Text(verbatim: L10n.Entities.unnamedItem)
                .textRole(.name)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        } else {
            HighlightedText(text: item.name, terms: terms)
                .textRole(.name)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var secondLine: some View {
        if line == .where {
            LocationLine(place: item, size: .row)
        } else if let text = ItemRowText.secondLine(line, category: item.category, createdAt: item.createdAt, count: tool.kind.foldsQuantity ? item.quantity : nil, now: now) {
            Text(Self.attributed(text))
                .textRole(.meta)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The folded count in front, in the signal colour at zero, then the rest, quietly.
    private static func attributed(_ line: ItemRowSecondLineText) -> AttributedString {
        var result = AttributedString()
        if let lead = line.lead {
            var part = AttributedString(lead.text)
            part.foregroundColor = lead.isNoneLeft ? DesignColor.signal : .primary
            part.font = TextRole.meta.font.weight(.semibold)
            result += part
            if line.rest != nil {
                var separator = AttributedString(L10n.Rows.separator)
                separator.foregroundColor = .secondary
                result += separator
            }
        }
        if let rest = line.rest {
            var part = AttributedString(rest)
            part.foregroundColor = .secondary
            result += part
        }
        return result
    }
}

/// What the row watches to keep its quantity model current.
private struct QuantitySync: Equatable {
    let quantity: Int
    let updatedAt: Int64
}

extension ItemRow.Tool {
    /// The chip, expanded when the list's one expanded id is this item's; tapping toggles it.
    static func chip(_ model: SavedQuantityModel, itemId: String, expandedId: Binding<String?>) -> ItemRow.Tool {
        .chip(model, isExpanded: expandedId.wrappedValue == itemId) {
            expandedId.wrappedValue = expandedId.wrappedValue == itemId ? nil : itemId
        }
    }
}

#if DEBUG
#Preview("Item rows") {
    @Previewable @State var expanded: String? = ComponentsFixtures.screws.id
    List {
        ItemRow(item: ComponentsFixtures.drill, tool: .chip(ComponentsFixtures.quantityModel(for: ComponentsFixtures.drill), itemId: ComponentsFixtures.drill.id, expandedId: $expanded), onPress: {})
        ItemRow(item: ComponentsFixtures.screws, tool: .chip(ComponentsFixtures.quantityModel(for: ComponentsFixtures.screws), itemId: ComponentsFixtures.screws.id, expandedId: $expanded), onPress: {})
        ItemRow(item: ComponentsFixtures.batteries, tool: .stepper(ComponentsFixtures.quantityModel(for: ComponentsFixtures.batteries)), onPress: {})
        ItemRow(item: ComponentsFixtures.waiting, line: .added, tool: .file({}), onPress: {})
        ItemRow(item: ComponentsFixtures.unnamed, line: .added, tool: .delete({}), onPress: {})
        ItemRow(item: ComponentsFixtures.screws, line: .detail, tool: .none, terms: ["screw"], onPress: {})
    }
}
#endif
