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
            // (a disabled list button would fade them to near nothing). VoiceOver still hears a
            // dimmed button, and cannot activate it.
            label
                .accessibilityRepresentation {
                    Button(action: action) { Text(verbatim: accessibilityLabel ?? "") }
                        .disabled(true)
                }
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
    /// squeezing it into a column a few letters wide.
    private var label: some View {
        HStack(alignment: alignment, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                content
                if layout.isStacked { aside }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !layout.isStacked { aside }
            if showsChevron {
                Image(glyph: .chevronRight)
                    .font(.footnote.weight(.semibold))
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
        if layout.isStacked {
            VStack(alignment: .trailing, spacing: 4) {
                row
                // The whole line under the row, not just the control, so a tap on the blank
                // space beside the control does not open the row.
                tool.buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .absorbsListRowTaps()
            }
        } else {
            HStack(spacing: 8) {
                row
                tool.buttonStyle(.borderless).absorbsListRowTaps()
            }
        }
    }
}

extension View {
    /// Stops taps on the blank parts of a row's control area (around a stepper, beside "Done")
    /// from falling through to the list row's button, which takes the whole cell, and opening
    /// the item. The controls on top still get their own taps.
    func absorbsListRowTaps() -> some View {
        background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)
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
