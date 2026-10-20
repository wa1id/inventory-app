import SwiftUI
import InventoryAppModels
import InventoryStrings

/// How a labelled field behaves at the keyboard.
struct LabeledFieldInput {
    /// Cuts what is typed to this many characters (RN `maxLength`).
    var maxLength: Int?
    /// The return key: `.next` when Return moves on to another field (RN `nextRef`).
    var submitLabel: SubmitLabel = .return
    /// Return was pressed: move focus on, or save.
    var onSubmit: (() -> Void)?
    var capitalization: TextInputAutocapitalization?
    var disablesAutocorrection = false
    var keyboard: UIKeyboardType = .default

    init(
        maxLength: Int? = nil,
        submitLabel: SubmitLabel = .return,
        onSubmit: (() -> Void)? = nil,
        capitalization: TextInputAutocapitalization? = nil,
        disablesAutocorrection: Bool = false,
        keyboard: UIKeyboardType = .default
    ) {
        self.maxLength = maxLength
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
        self.capitalization = capitalization
        self.disablesAutocorrection = disablesAutocorrection
        self.keyboard = keyboard
    }
}

/// A labelled text field (RN `TextField`, 07 §4.10).
///
/// The label sits above in sentence case; "(optional)" follows it when asked; "required" is
/// announced, never drawn. An error replaces the hint with a warning line in red and is
/// announced (queued, as two fields can fail at once); whatever was typed stays. An optional
/// counter sits at the end of the label row and an optional accessory at the end of the field.
/// In a `Form` row it is a plain field; elsewhere use the `boxed` chrome. Focus chains through
/// the caller's `@FocusState`: pass `focus` and `field`, and move it on in `input.onSubmit`.
struct LabeledTextField<Field: Hashable, Trailing: View>: View {
    enum Chrome: Sendable {
        /// A plain field, for a `Form` or grouped `List` row.
        case formRow
        /// A rounded box, for a field outside a form.
        case boxed
    }

    let label: String
    @Binding var text: String
    var placeholder: String?
    var error: String?
    var hint: String?
    var isRequired = false
    var isOptional = false
    /// Multiline: a notes box of at least four lines, or with `grows` one line that grows.
    var isMultiline = false
    var grows = false
    var counter: String?
    /// What VoiceOver calls the field when the visible label is a question ("What is it?" is
    /// read as "Name").
    var accessibilityLabel: String?
    var input = LabeledFieldInput()
    var chrome: Chrome = .formRow
    var identifier: String?
    var focus: FocusState<Field?>.Binding?
    var field: Field?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            labelRow
            HStack(spacing: 8) {
                textField
                trailing
            }
            .padding(chrome == .boxed ? EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14) : EdgeInsets())
            .background {
                if chrome == .boxed {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(hasError ? DesignColor.signal : Color(uiColor: .separator), lineWidth: hasError ? 2 : 1)
                        )
                }
            }
            if let error, hasError {
                FieldMessage(text: error)
            } else if let hint, !hint.isEmpty {
                Text(verbatim: hint)
                    .textRole(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .announcesOnChange(TextFieldCopy.errorAnnouncement(error ?? ""), enabled: hasError, queued: true)
    }

    private var hasError: Bool { !(error ?? "").isEmpty }

    /// The label, and the counter at the end of its row; at large sizes the counter wraps under
    /// the label rather than squeezing it.
    private var labelRow: some View {
        AdaptiveStack(horizontalAlignment: .leading, verticalAlignment: .firstTextBaseline, spacing: 8) {
            Text(labelText)
                .textRole(.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let counter {
                Text(verbatim: counter)
                    .textRole(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityHidden(true)
    }

    private var labelText: AttributedString {
        var text = AttributedString(label)
        if isOptional {
            var suffix = AttributedString(" " + TextFieldCopy.optionalSuffix)
            suffix.foregroundColor = .secondary
            text += suffix
        }
        return text
    }

    private var limitedText: Binding<String> {
        guard let maxLength = input.maxLength else { return $text }
        return Binding(get: { text }, set: { text = String($0.prefix(maxLength)) })
    }

    @ViewBuilder
    private var textField: some View {
        let base = TextField(
            text: limitedText,
            prompt: Text(verbatim: placeholder ?? ""),
            axis: isMultiline ? .vertical : .horizontal
        ) {
            Text(verbatim: label)
        }
        .lineLimit(isMultiline && !grows ? 4... : 1...)
        .submitLabel(input.submitLabel)
        .onSubmit { input.onSubmit?() }
        .textInputAutocapitalization(input.capitalization)
        .autocorrectionDisabled(input.disablesAutocorrection)
        .keyboardType(input.keyboard)
        .accessibilityLabel(Text(verbatim: TextFieldCopy.spokenLabel(label: label, accessibilityLabel: accessibilityLabel, required: isRequired, error: error)))
        .accessibilityHintIfPresent(hint)
        .accessibilityIdentifierIfPresent(identifier)
        if let focus, let field {
            base.focused(focus, equals: field)
        } else {
            base
        }
    }
}

/// A warning line under a field or a stepper: the warning glyph and the sentence in red. Hidden
/// from VoiceOver, which hears it through the field's label and an announcement.
struct FieldMessage: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(glyph: .warning)
                .font(.footnote.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Text(verbatim: text)
                .textRole(.meta)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(DesignColor.signal)
        .accessibilityHidden(true)
    }
}

/// The focus type of a field outside a focus chain.
enum LabeledTextFieldNoFocus: Hashable {}

extension LabeledTextField where Trailing == EmptyView {
    /// A field in a focus chain.
    init(
        label: String,
        text: Binding<String>,
        placeholder: String? = nil,
        error: String? = nil,
        hint: String? = nil,
        isRequired: Bool = false,
        isOptional: Bool = false,
        isMultiline: Bool = false,
        grows: Bool = false,
        counter: String? = nil,
        accessibilityLabel: String? = nil,
        input: LabeledFieldInput = LabeledFieldInput(),
        chrome: Chrome = .formRow,
        identifier: String? = nil,
        focus: FocusState<Field?>.Binding,
        field: Field
    ) {
        self.init(
            label: label, text: text, placeholder: placeholder, error: error, hint: hint, isRequired: isRequired,
            isOptional: isOptional, isMultiline: isMultiline, grows: grows, counter: counter,
            accessibilityLabel: accessibilityLabel, input: input, chrome: chrome, identifier: identifier,
            focus: focus, field: field, trailing: { EmptyView() }
        )
    }
}

extension LabeledTextField where Field == LabeledTextFieldNoFocus, Trailing == EmptyView {
    /// A field on its own.
    init(
        label: String,
        text: Binding<String>,
        placeholder: String? = nil,
        error: String? = nil,
        hint: String? = nil,
        isRequired: Bool = false,
        isOptional: Bool = false,
        isMultiline: Bool = false,
        grows: Bool = false,
        counter: String? = nil,
        accessibilityLabel: String? = nil,
        input: LabeledFieldInput = LabeledFieldInput(),
        chrome: Chrome = .formRow,
        identifier: String? = nil
    ) {
        self.init(
            label: label, text: text, placeholder: placeholder, error: error, hint: hint, isRequired: isRequired,
            isOptional: isOptional, isMultiline: isMultiline, grows: grows, counter: counter,
            accessibilityLabel: accessibilityLabel, input: input, chrome: chrome, identifier: identifier,
            focus: nil, field: nil, trailing: { EmptyView() }
        )
    }
}

#Preview("Fields") {
    @Previewable @State var name = ""
    @Previewable @State var notes = "Bought in 2024"
    Form {
        LabeledTextField(label: "Name", text: $name, placeholder: "Cordless drill", isRequired: true)
        LabeledTextField(label: "Name", text: $name, error: "Give it a name.", isRequired: true)
        LabeledTextField(label: "Tags", text: $name, placeholder: "power tools, blue", hint: "Separate tags with commas", isOptional: true)
        LabeledTextField(label: "Notes", text: $notes, isMultiline: true)
    }
}
