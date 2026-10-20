import SwiftUI

/// The base of every list row (RN `Row`, 06 §15.1): a pressable area with a leading view, a text
/// column, an aside and an optional chevron.
///
/// Inside a `List` the pressable area is a plain `Button`, so the list draws the system row
/// highlight. A control that belongs to the row (a stepper, "File…", a trash button) is never
/// inside it: wrap the row in ``RowWithTool`` so the control is a sibling with its own
/// VoiceOver stop, and a tap on it never opens the row.
struct ListRow<Leading: View, Content: View, Aside: View>: View {
    var action: (() -> Void)?
    var showsChevron = false
    var isSelected = false
    /// Not pressable and announced as dimmed; callers draw their text in the secondary style.
    var isDisabled = false
    var minHeight: CGFloat = 44
    /// How the leading view, text and aside line up: centred, or `.top` under a control that sits
    /// on the first line (the quantity chip).
    var alignment: VerticalAlignment = .center
    /// The whole row speaks as one element with this label (required when pressable).
    var accessibilityLabel: String?
    var accessibilityHint: String?
    var identifier: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var content: Content
    @ViewBuilder var aside: Aside

    private let layout = LayoutScale()

    var body: some View {
        if let action, isDisabled {
            // Not pressable, but not dimmed either (RN `Row`): "Here now" and its tape stay
            // readable in the secondary text the caller chose, also under the picker's busy fade
            // (a disabled list button in the stock style would fade them to near nothing). A real
            // disabled button, drawn by a style that leaves the label as it is, and left as its
            // own element (a button speaks as one already), so VoiceOver hears a dimmed button
            // it cannot activate; a replacement element would drop the dimmed state.
            Button(action: action) { label }
                .buttonStyle(ListRowUndimmedStyle())
                .disabled(true)
                .accessibilityLabelIfPresent(accessibilityLabel)
                .accessibilityHintIfPresent(accessibilityHint)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifierIfPresent(identifier)
        } else if let action {
            Button(action: action) { label.contentShape(Rectangle()) }
                .foregroundStyle(.primary)
                .modifier(RowAccessibility(label: accessibilityLabel, hint: accessibilityHint, isSelected: isSelected, isButton: true, identifier: identifier))
        } else {
            label
                .modifier(RowAccessibility(label: accessibilityLabel, hint: accessibilityHint, isSelected: isSelected, isButton: false, identifier: identifier))
        }
    }

    /// At large text sizes the aside (a badge, a tape, a count) goes under the text instead of
    /// squeezing it into a column a few letters wide. One tree at every size (a layout moves the
    /// aside), so growing text keeps the row's views rather than building new ones.
    private var label: some View {
        HStack(alignment: alignment, spacing: 12) {
            leading
            ListRowTextLayout(isStacked: layout.isStacked, alignment: alignment) {
                // A container of its own: a lone name would otherwise take the whole row as its
                // frame, tape and all, and Xcode's audit then measures the tape's yellow as the
                // name's contrast.
                VStack(alignment: .leading, spacing: 2) {
                    content
                }
                .accessibilityElement(children: .contain)
                HStack(spacing: 8) {
                    aside
                }
            }
            if showsChevron {
                Image(glyph: .chevronRight)
                    .font(.footnote.weight(.semibold))
                    // A decorative indicator, like the system's: it stops at 1.6× so the row's
                    // words keep the room at the largest sizes (a wider chevron broke
                    // "containers" inside the word at AX5).
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: minHeight)
    }
}

extension ListRow where Aside == EmptyView {
    init(
        action: (() -> Void)?,
        showsChevron: Bool = false,
        isSelected: Bool = false,
        isDisabled: Bool = false,
        minHeight: CGFloat = 44,
        alignment: VerticalAlignment = .center,
        accessibilityLabel: String? = nil,
        accessibilityHint: String? = nil,
        identifier: String? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            action: action,
            showsChevron: showsChevron,
            isSelected: isSelected,
            isDisabled: isDisabled,
            minHeight: minHeight,
            alignment: alignment,
            accessibilityLabel: accessibilityLabel,
            accessibilityHint: accessibilityHint,
            identifier: identifier,
            leading: leading,
            content: content,
            aside: { EmptyView() }
        )
    }
}

/// A row's text column and its aside: the text takes the width the aside leaves and the aside
/// sits at the trailing edge, or, stacked, the aside goes under the text at the leading edge.
/// Exactly two subviews (the text, then the aside's stack, which is empty without an aside).
private struct ListRowTextLayout: Layout {
    var isStacked: Bool
    var alignment: VerticalAlignment
    var spacing: CGFloat = 12
    var stackedSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return subviews.first?.sizeThatFits(proposal) ?? .zero }
        let text = subviews[0], aside = subviews[1]
        let asideIdeal = aside.sizeThatFits(.unspecified)
        if isStacked {
            let width = proposal.width
            let textSize = text.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let asideSize = aside.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let gap = asideSize.height > 0 ? stackedSpacing : 0
            return CGSize(width: width ?? max(textSize.width, asideSize.width), height: textSize.height + gap + asideSize.height)
        }
        let gap = asideIdeal.width > 0 ? spacing : 0
        guard let width = proposal.width else {
            let textSize = text.sizeThatFits(.unspecified)
            return CGSize(width: textSize.width + gap + asideIdeal.width, height: max(textSize.height, asideIdeal.height))
        }
        let textSize = text.sizeThatFits(ProposedViewSize(width: max(0, width - gap - asideIdeal.width), height: nil))
        return CGSize(width: width, height: max(textSize.height, asideIdeal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let text = subviews[0], aside = subviews[1]
        if isStacked {
            let width = ProposedViewSize(width: bounds.width, height: nil)
            let textSize = text.sizeThatFits(width)
            let asideSize = aside.sizeThatFits(width)
            let gap = asideSize.height > 0 ? stackedSpacing : 0
            text.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: textSize.height))
            aside.place(at: CGPoint(x: bounds.minX, y: bounds.minY + textSize.height + gap), proposal: ProposedViewSize(asideSize))
            return
        }
        let asideSize = aside.sizeThatFits(.unspecified)
        let gap = asideSize.width > 0 ? spacing : 0
        let textWidth = max(0, bounds.width - gap - asideSize.width)
        let textSize = text.sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
        text.place(at: CGPoint(x: bounds.minX, y: y(for: textSize.height, in: bounds)), proposal: ProposedViewSize(width: textWidth, height: textSize.height))
        aside.place(at: CGPoint(x: bounds.maxX - asideSize.width, y: y(for: asideSize.height, in: bounds)), proposal: ProposedViewSize(asideSize))
    }

    /// Top, bottom or centred in the row, as the row's `alignment` asks.
    private func y(for height: CGFloat, in bounds: CGRect) -> CGFloat {
        switch alignment {
        case .top, .firstTextBaseline: bounds.minY
        case .bottom, .lastTextBaseline: bounds.maxY - height
        default: bounds.minY + (bounds.height - height) / 2
        }
    }
}

/// A row that cannot be pressed: the label exactly as the caller drew it (the stock styles fade a
/// disabled label).
private struct ListRowUndimmedStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct RowAccessibility: ViewModifier {
    let label: String?
    let hint: String?
    let isSelected: Bool
    /// Pressable: one element replacing the button keeps no traits of its own, so the row says
    /// "button" explicitly (RN `accessibilityRole="button"`).
    let isButton: Bool
    let identifier: String?

    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: label))
                .accessibilityHintIfPresent(hint)
                .accessibilityAddTraits(isButton ? .isButton : [])
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifierIfPresent(identifier)
        } else {
            content
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifierIfPresent(identifier)
        }
    }
}

/// A row and its control side by side, the control a sibling of the row's pressable area,
/// never inside it (RN `Row`'s `tool`). At large text sizes the control drops under the text,
/// at the trailing edge, instead of squeezing it.
struct RowWithTool<Row: View, Tool: View>: View {
    @ViewBuilder var row: Row
    @ViewBuilder var tool: Tool

    private let layout = LayoutScale()

    var body: some View {
        let stacked = layout.isStacked
        // One tree in both shapes (a layout swap, not two branches), so growing text keeps the
        // row and its control, and VoiceOver's place on them.
        let shape = stacked
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        shape {
            row
            // Stacked, the whole line under the row, not just the control, so a tap on the blank
            // space beside the control does not open the row.
            tool.buttonStyle(.borderless)
                .frame(maxWidth: stacked ? .infinity : nil, alignment: .trailing)
                .absorbsListRowTaps()
        }
    }
}

extension View {
    /// Stops taps on the blank parts of a row's control area (around a stepper, beside "Done")
    /// from falling through to the list row's button, which takes the whole cell, and opening
    /// the item. The controls on top still get their own taps. With `active` false nothing is
    /// drawn behind; the switch is inside the background, so the control keeps its identity.
    func absorbsListRowTaps(_ active: Bool = true) -> some View {
        background {
            if active {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
            }
        }
    }
}

#Preview {
    List {
        ListRow(action: {}, showsChevron: true, accessibilityLabel: "Garage") {
            SpaceTile(icon: "🚗", color: "#5B8DEF", size: 48)
        } content: {
            Text(verbatim: "Garage").textRole(.name)
            Text(verbatim: "2 containers and 5 items").textRole(.meta).foregroundStyle(.secondary)
        }
        RowWithTool {
            ListRow(action: {}, accessibilityLabel: "Drill") {
                Thumb(uri: nil)
            } content: {
                Text(verbatim: "Drill").textRole(.name)
            }
        } tool: {
            Button("File…") {}.buttonStyle(.bordered)
        }
    }
}
