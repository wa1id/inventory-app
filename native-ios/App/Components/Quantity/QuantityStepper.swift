import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// Minus, the number, plus (RN `QuantityStepper`, 07 §4.7). Controlled and free of I/O: the Add
/// form holds the value, ``SavedQuantityStepper`` writes it through.
///
/// The behaviour is ``QuantityHoldRepeater``'s: a tap steps by one; holding steps after 400 ms,
/// then every 80 ms until release or a bound; haptics tick on steps (every fifth while
/// repeating) and land heavier on zero. Tapping the number types one; it commits on Done, on
/// Return or when the field is left, and anything that is not a whole number reverts. Not a
/// stock `Stepper`, which has no typed entry.
///
/// VoiceOver gets one adjustable element: swipe up or down to step, and the "Type a number"
/// action to type.
struct QuantityStepper: View {
    enum Size: Sendable {
        /// 48 pt cells, in list rows.
        case compact
        /// 56 pt cells, with an error line under it.
        case large

        var cell: CGFloat { self == .compact ? 48 : 56 }
        var numberWidth: CGFloat { self == .compact ? 56 : 80 }
        var role: TextRole { self == .compact ? .stepper : .stepperL }
    }

    let value: Int
    let onChange: (Int) -> Void
    var size: Size = .large
    /// Names the item in every label: "Increase quantity of Wood screws".
    var itemName: String?
    /// The large size only: shown under the stepper and announced.
    var error: String?
    var isDisabled = false
    /// Appended to the identifiers in lists; bare on the item screen and the Add form.
    var identifierSuffix: String?
    /// Reports each whole number as it is typed (the Add form, whose Save sits outside the
    /// scroll view).
    var commitWhileTyping = false

    @Environment(\.haptics) private var haptics
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var relay: QuantityStepperRelay
    @State private var repeater: QuantityHoldRepeater
    @State private var pressed: QuantityHoldRepeater.Direction?
    @State private var selection: TextSelection?
    @FocusState private var fieldFocused: Bool
    private let layout = LayoutScale()

    init(
        value: Int,
        onChange: @escaping (Int) -> Void,
        size: Size = .large,
        itemName: String? = nil,
        error: String? = nil,
        isDisabled: Bool = false,
        identifierSuffix: String? = nil,
        commitWhileTyping: Bool = false
    ) {
        self.value = value
        self.onChange = onChange
        self.size = size
        self.itemName = itemName
        self.error = error
        self.isDisabled = isDisabled
        self.identifierSuffix = identifierSuffix
        self.commitWhileTyping = commitWhileTyping
        let relay = QuantityStepperRelay()
        _relay = State(initialValue: relay)
        _repeater = State(
            initialValue: QuantityHoldRepeater(
                value: value,
                isDisabled: isDisabled,
                commitWhileTyping: commitWhileTyping,
                haptics: { relay.play($0) },
                onChange: { relay.changed($0) }
            )
        )
    }

    private var fills: Bool { size == .large && layout.isStacked }

    var body: some View {
        let _ = relay.update(onChange: onChange, haptics: haptics)
        VStack(alignment: .leading, spacing: 6) {
            control
            if size == .large, let error, !error.isEmpty {
                FieldMessage(text: error)
            }
        }
        .announcesOnChange(error ?? "", enabled: size == .large && !(error ?? "").isEmpty)
        .onChange(of: value) { _, next in repeater.value = next }
        .onChange(of: isDisabled) { _, next in repeater.isDisabled = next }
        .onChange(of: fieldFocused) { _, focused in
            if focused {
                repeater.beginEditing()
                let text = repeater.fieldText
                selection = TextSelection(range: text.startIndex..<text.endIndex)
            } else {
                repeater.commitTyped()
            }
        }
        .onDisappear { repeater.pressCancelled() }
    }

    private var control: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(spacing: 0) {
            stepButton(.minus)
            Divider()
            numberField
            Divider()
            stepButton(.plus)
        }
        .frame(height: size.cell)
        .frame(maxWidth: fills ? .infinity : nil)
        .background(shape.fill(Color(uiColor: .tertiarySystemFill)))
        .overlay(shape.strokeBorder(error == nil ? Color.clear : DesignColor.signal, lineWidth: 1))
        .clipShape(shape)
        .opacity(isDisabled ? 0.45 : 1)
        .fixedSize(horizontal: !fills, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: QuantityStepperCopy.fieldLabel(itemName: itemName)))
        .accessibilityValue(Text(verbatim: QuantityStepperCopy.valueText(repeater.value)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: repeater.step(.plus)
            case .decrement: repeater.step(.minus)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text(verbatim: L10n.Quantity.typeNumber)) {
            if !isDisabled { fieldFocused = true }
        }
    }

    private var numberField: some View {
        TextField(
            "",
            text: Binding(get: { repeater.fieldText }, set: { repeater.typeDraft($0) }),
            selection: $selection
        )
        .focused($fieldFocused)
        .keyboardType(.numberPad)
        .multilineTextAlignment(.center)
        .textRole(size.role)
        .foregroundStyle(repeater.value <= minQuantity && repeater.draft == nil ? DesignColor.signal : .primary)
        .frame(minWidth: numberFieldWidth, maxWidth: fills ? .infinity : nil)
        .frame(maxHeight: .infinity)
        .disabled(isDisabled)
        .onSubmit { repeater.commitTyped() }
        .toolbar {
            if fieldFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.Quantity.done) { fieldFocused = false }
                }
            }
        }
        .accessibilityIdentifier(QuantityStepperCopy.identifier("input", suffix: identifierSuffix))
    }

    /// Wide enough for the digits at the capped text size, so "9999" never clips (RN
    /// `numberFieldWidth`): a heavy tabular digit is about 0.66 em wide.
    private var numberFieldWidth: CGFloat {
        let digits = max(String(repeater.value).count, repeater.draft?.count ?? 0)
        let capped = min(dynamicTypeSize, size.role.maximumSize ?? dynamicTypeSize)
        let style: UIFont.TextStyle = size == .compact ? .body : .title2
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(capped))
        let pointSize = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
        return max(size.numberWidth, (CGFloat(digits) * pointSize * 0.66 + 12).rounded(.up))
    }

    private func stepButton(_ direction: QuantityHoldRepeater.Direction) -> some View {
        let off = direction == .minus ? repeater.isMinusDisabled : repeater.isPlusDisabled
        let cell = size.cell
        return Image(glyph: direction == .minus ? .minus : .plus)
            // A fixed glyph in a fixed cell (RN 20 / 24 pt); the number beside it scales.
            .font(.system(size: size == .compact ? 20 : 24, weight: .semibold))
            .foregroundStyle(off ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .frame(width: cell, height: cell)
            .background(pressed == direction ? Color(uiColor: .systemFill) : .clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if pressed == nil {
                            pressed = direction
                            if fieldFocused { fieldFocused = false }
                            repeater.pressBegan(direction)
                        } else if !CGRect(x: -24, y: -24, width: cell + 48, height: cell + 48).contains(drag.location) {
                            pressed = nil
                            repeater.pressCancelled()
                        }
                    }
                    .onEnded { _ in
                        guard pressed != nil else { return }
                        pressed = nil
                        repeater.pressEnded()
                    },
                including: off ? .none : .all
            )
            .accessibilityIdentifier(QuantityStepperCopy.identifier(direction == .minus ? "decrease" : "increase", suffix: identifierSuffix))
            .accessibilityLabel(
                Text(verbatim: direction == .minus ? QuantityStepperCopy.decreaseLabel(itemName: itemName) : QuantityStepperCopy.increaseLabel(itemName: itemName))
            )
    }
}

/// Forwards the repeater's haptics and changes to whatever the view currently holds: the
/// repeater is made once, the view's closures and environment are not.
@MainActor
final class QuantityStepperRelay {
    private var onChange: (Int) -> Void = { _ in }
    private var haptics: HapticPlayer = { _ in }

    func update(onChange: @escaping (Int) -> Void, haptics: @escaping HapticPlayer) {
        self.onChange = onChange
        self.haptics = haptics
    }

    func changed(_ value: Int) { onChange(value) }
    func play(_ event: HapticEvent) { haptics(event) }
}

/// The large stepper over a saved item: plus and minus write through at once, with no Save
/// button (RN `SavedQuantityStepper`, 07 §4.8).
///
/// ``SavedQuantityModel`` makes the writes optimistic, coalesced and retried; a failed one snaps
/// the number back with a sentence under it. At zero, with no error, "None left right now"
/// shows. The compact size has no room for sentences: the model's `onError` reports instead
/// (a toast naming the item, `SavedQuantityModel.notSavedMessage`).
struct SavedQuantityStepper: View {
    let model: SavedQuantityModel
    /// The item's name; blank keeps the labels generic.
    let itemName: String
    var size: QuantityStepper.Size = .large
    var identifierSuffix: String?

    private let layout = LayoutScale()

    var body: some View {
        VStack(alignment: size == .large && !layout.isStacked ? .trailing : .leading, spacing: 6) {
            QuantityStepper(
                value: model.quantity,
                onChange: { model.setQuantity($0) },
                size: size,
                itemName: SavedQuantityModel.labelName(itemName),
                error: size == .large ? model.error : nil,
                identifierSuffix: identifierSuffix
            )
            if size == .large && model.showsNoneRightNow {
                Text(verbatim: L10n.Quantity.noneRightNow)
                    .textRole(.meta)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignColor.signal)
            }
        }
    }
}

/// How many are left, on every row, and the way to change it (RN `QuantityChip`, 07 §4.9).
///
/// "×1" shows too, so there is always something to tap; at zero it says "None left" in red.
/// Tapping toggles the large stepper under the row: two taps to change a count from a search
/// result. One row is expanded per list; the list holds which.
struct QuantityChip: View {
    let quantity: Int
    let itemName: String
    let itemId: String
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        let words = ItemRowText.quantity(quantity)
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Text(verbatim: words.text)
                    .textRole(.aside)
                    .lineLimit(1)
                if isExpanded {
                    Image(glyph: .chevronDown)
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(180))
                }
            }
            .foregroundStyle(words.isNoneLeft ? DesignColor.signal : .primary)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(words.isNoneLeft ? DesignColor.signal : nil)
        .overlay(Capsule().strokeBorder(isExpanded ? Color.accentColor : .clear, lineWidth: 2))
        .frame(minWidth: DesignMetrics.minTouchTarget, minHeight: DesignMetrics.minTouchTarget)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(verbatim: ItemRowText.chipAccessibilityLabel(name: itemName, quantity: quantity)))
        .accessibilityHint(Text(verbatim: ItemRowText.chipAccessibilityHint))
        // RN's `expanded` state: the open chip reads as selected.
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .accessibilityIdentifier(ItemRowText.chipIdentifier(itemId))
    }
}

#Preview("Steppers") {
    @Previewable @State var count = 3
    @Previewable @State var zero = 0
    Form {
        QuantityStepper(value: count, onChange: { count = $0 }, itemName: "Wood screws")
        QuantityStepper(value: zero, onChange: { zero = $0 }, size: .compact)
        QuantityStepper(value: 9999, onChange: { _ in }, error: "The quantity was not saved. Try again.")
        QuantityStepper(value: 2, onChange: { _ in }, isDisabled: true)
        HStack {
            QuantityChip(quantity: 3, itemName: "Screws", itemId: "a", isExpanded: false, onToggle: {})
            QuantityChip(quantity: 0, itemName: "Screws", itemId: "b", isExpanded: false, onToggle: {})
            QuantityChip(quantity: 12, itemName: "Screws", itemId: "c", isExpanded: true, onToggle: {})
        }
    }
}
