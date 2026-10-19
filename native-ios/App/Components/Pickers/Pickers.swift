import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// A small pill (RN `Chip`): a display tag without an action (an item's tags), or a tappable
/// suggestion with one (recent categories under the Category field).
struct TagChip: View {
    let label: String
    var isSelected = false
    var identifier: String?
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                Text(verbatim: label).textRole(.meta).fontWeight(.semibold)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(isSelected ? .accentColor : nil)
            .overlay(Capsule().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifierIfPresent(identifier)
        } else {
            Text(verbatim: label)
                .textRole(.meta)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(Capsule().fill(.quaternary))
                .overlay(Capsule().strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
                .accessibilityIdentifierIfPresent(identifier)
        }
    }
}

/// One option of a ``ChoiceList``.
struct ChoiceOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var subtitle: String?
    /// A leading picture (a space tile).
    var leading: AnyView?
    var identifier: String?

    var id: Value { value }
}

/// A single choice from a short list, every option visible (RN `ChoiceList`): a stock inline
/// picker with checkmarks, in a form section. Choosing a new option plays the choice haptic;
/// choosing the current one does nothing.
struct ChoiceList<Value: Hashable>: View {
    let options: [ChoiceOption<Value>]
    @Binding var selection: Value
    let accessibilityLabel: String

    @Environment(\.haptics) private var haptics

    var body: some View {
        Picker(selection: Binding(get: { selection }, set: { choose($0) })) {
            ForEach(options) { option in
                HStack(spacing: 12) {
                    if let leading = option.leading { leading }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: option.title).textRole(.name)
                        if let subtitle = option.subtitle {
                            Text(verbatim: subtitle).textRole(.meta).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifierIfPresent(option.identifier)
                .tag(option.value)
            }
        } label: {
            Text(verbatim: accessibilityLabel)
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    private func choose(_ value: Value) {
        guard value != selection else { return }
        haptics(.choice)
        selection = value
    }
}

/// A space's icon: a wrapping grid of 48 pt tiles tinted in the chosen colour (RN
/// `EmojiPicker`). The presets' icons are offered too, and a stored icon in neither list comes
/// first, selected. Each tile is read by name ("Toolbox"), not by its emoji description.
struct EmojiPicker: View {
    let label: String
    @Binding var value: String
    /// The space's colour, so each choice is previewed as it will look.
    let color: String
    var options: [String] = SpacePalette.icons

    @Environment(\.haptics) private var haptics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: label).textRole(.label).accessibilityHidden(true)
            SpreadGrid(tileWidth: 52, minGap: 8, rowGap: 8) {
                ForEach(SpacePalette.iconChoices(options: options, value: value)) { choice in
                    Button {
                        guard !choice.isSelected else { return }
                        haptics(.choice)
                        value = choice.icon
                    } label: {
                        SpaceTile(icon: choice.icon, color: color, size: 48)
                            .padding(2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(choice.isSelected ? Color.accentColor : .clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: choice.name))
                    .accessibilityAddTraits(choice.isSelected ? .isSelected : [])
                    .accessibilityIdentifier(choice.identifier)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: label))
        }
    }
}

/// A space's colour: 44 pt swatches, each read by its colour's name (RN `SwatchPicker`). The
/// checkmark on the selected one uses `onColor`, so it reads on every palette entry. A stored
/// colour outside the palette comes first as the selected "Current colour", so editing a space
/// never silently changes it.
struct SwatchPicker: View {
    let label: String
    @Binding var value: String
    var palette: [String] = SpacePalette.colors

    @Environment(\.haptics) private var haptics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: label).textRole(.label).accessibilityHidden(true)
            SpreadGrid(tileWidth: 48, minGap: 4, rowGap: 4) {
                ForEach(SpacePalette.colourChoices(palette: palette, value: value)) { choice in
                    Button {
                        guard !choice.isSelected else { return }
                        haptics(.choice)
                        value = choice.swatch
                    } label: {
                        Circle()
                            .fill(Color(spaceHex: choice.fill))
                            .overlay(Circle().strokeBorder(Color(.pipRing), lineWidth: 1))
                            .overlay {
                                if choice.isSelected {
                                    Image(glyph: .check)
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(Color(spaceHex: choice.checkColor))
                                }
                            }
                            .frame(width: 40, height: 40)
                            .padding(2)
                            .overlay(Circle().strokeBorder(choice.isSelected ? Color.accentColor : .clear, lineWidth: 2))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: choice.name))
                    .accessibilityAddTraits(choice.isSelected ? .isSelected : [])
                    .accessibilityIdentifier(choice.identifier)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: label))
        }
    }
}

/// One option of a ``SegmentedChoice``.
struct SegmentOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var glyph: Glyph?
    var identifier: String?

    var id: Value { value }
}

/// Two to four mutually exclusive options (RN `SegmentedControl`): a stock segmented picker.
/// The camera tone puts it on glass over the picture.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [SegmentOption<Value>]
    @Binding var selection: Value
    let accessibilityLabel: String
    var onCamera = false
    var isDisabled = false
    /// Read on each option (why the control is locked).
    var accessibilityHint: String?

    @Environment(\.haptics) private var haptics

    var body: some View {
        Picker(selection: Binding(get: { selection }, set: { choose($0) })) {
            ForEach(options) { option in
                Group {
                    if let glyph = option.glyph {
                        Label(option.label, glyph: glyph)
                    } else {
                        Text(verbatim: option.label)
                    }
                }
                .accessibilityIdentifierIfPresent(option.identifier)
                .tag(option.value)
            }
        } label: {
            Text(verbatim: accessibilityLabel)
        }
        .pickerStyle(.segmented)
        .disabled(isDisabled)
        .accessibilityHintIfPresent(accessibilityHint)
        .modifier(CameraSegmentChrome(onCamera: onCamera))
    }

    private func choose(_ value: Value) {
        guard value != selection else { return }
        haptics(.choice)
        selection = value
    }
}

private struct CameraSegmentChrome: ViewModifier {
    let onCamera: Bool

    func body(content: Content) -> some View {
        if onCamera {
            content
                .padding(4)
                .glassEffect(.regular, in: .capsule)
                .environment(\.colorScheme, .dark)
        } else {
            content
        }
    }
}

/// Container types as large symbol tiles, four to a row (three in windows narrower than 360 pt),
/// flush with both edges (RN `TypeGrid`). Only the selected tile spells its name underneath;
/// every tile keeps room for it, so choosing one never moves the others, and every tile is read
/// by name. A stored type this build does not know selects no tile and is kept unless a tile is
/// tapped.
struct TypeGrid: View {
    let label: String
    @Binding var value: ContainerVisualType

    @Environment(\.haptics) private var haptics
    private let layout = LayoutScale()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: label).textRole(.label).accessibilityHidden(true)
            SpreadGrid(tileWidth: 72, minGap: 8, rowGap: 12, maxColumns: layout.isNarrow ? 3 : 4) {
                ForEach(ContainerVisualType.allKnown, id: \.self) { type in
                    tile(type)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: label))
        }
    }

    private func tile(_ type: ContainerVisualType) -> some View {
        let selected = type == value
        let name = PlaceRowText.typeName(type)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(spacing: 4) {
            Button {
                guard !selected else { return }
                haptics(.choice)
                value = type
            } label: {
                Image(glyph: Glyph.container(type))
                    .font(.system(size: 28))
                    .foregroundStyle(.primary)
                    .frame(width: 72, height: 72)
                    .background(shape.fill(selected ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground)))
                    .overlay(shape.strokeBorder(selected ? Color.accentColor : Color(uiColor: .separator), lineWidth: selected ? 2 : 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: name))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("tile-\(type.rawValue)")
            // Under a fixed 72 pt tile the name may shrink at the largest sizes rather than clip.
            Text(verbatim: name)
                .textRole(.caption)
                .fontWeight(.semibold)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
                .opacity(selected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(width: 72)
    }
}

#Preview("Pickers") {
    @Previewable @State var icon = "🧰"
    @Previewable @State var color = "#5B8DEF"
    @Previewable @State var type: ContainerVisualType = .drawer
    @Previewable @State var mode = "single"
    Form {
        Section {
            HStack {
                TagChip(label: "power tools")
                TagChip(label: "Tools") {}
                TagChip(label: "Kitchen", isSelected: true) {}
            }
        }
        Section { EmojiPicker(label: "Icon", value: $icon, color: color) }
        Section { SwatchPicker(label: "Colour", value: $color) }
        Section { TypeGrid(label: "Type", value: $type) }
        Section {
            SegmentedChoice(
                options: [SegmentOption(value: "single", label: "Single"), SegmentOption(value: "several", label: "Several", glyph: .layers)],
                selection: $mode,
                accessibilityLabel: "Mode"
            )
        }
    }
}
