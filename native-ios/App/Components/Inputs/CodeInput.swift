import SwiftUI
import InventoryAppModels
import InventoryCore

/// A household or recovery code field (RN `CodeInput`, 07 §4.10, 03 §3.5).
///
/// Shown in groups of five while typing; lower case, missing hyphens, pasted spaces and line
/// breaks, and the look-alikes I, L and O are all fine, because every change is normalised; a
/// paste never submits on its own.
/// Validity is the screen's call, on submit; nothing is cut to the expected length. A whole code
/// is wider than a phone, so the field wraps at its hyphens instead of scrolling it out of
/// sight. Return closes the keyboard and submits; it never adds a line. The counter ("12 of 26
/// characters") is read once on leaving the field, not on every keystroke.
struct CodeInput: View {
    let label: String
    /// The normalised code: upper case, no hyphens, look-alikes folded.
    @Binding var value: String
    var length = codeLength
    var hint: String?
    var error: String?
    var identifier: String?
    var onSubmit: (() -> Void)?

    @FocusState private var focus: CodeInputFocus?

    var body: some View {
        LabeledTextField(
            label: label,
            text: Binding(get: { CodeFieldText.display(value) }, set: { typed($0) }),
            error: error,
            hint: hint,
            isMultiline: true,
            grows: true,
            counter: CodeFieldText.visibleCounter(value, length: length),
            input: LabeledFieldInput(
                submitLabel: .done,
                onSubmit: submit,
                capitalization: .characters,
                disablesAutocorrection: true,
                keyboard: .asciiCapable
            ),
            chrome: .boxed,
            identifier: identifier,
            focus: $focus,
            field: .code
        ) {
            Image(glyph: .lock)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .textRole(.code)
        .textContentType(nil)
        .onChange(of: focus) { old, new in
            if old == .code && new == nil {
                ComponentAnnouncer.announce(CodeFieldText.counter(value, length: length))
            }
        }
    }

    private func typed(_ text: String) {
        let returnKey = CodeFieldText.isReturnKey(shown: CodeFieldText.display(value), typed: text)
        value = CodeFieldText.normalise(text)
        if returnKey { submit() }
    }

    /// Once per key press: the Return key can arrive both as a line break and as a submit.
    private func submit() {
        guard focus == .code else { return }
        focus = nil
        onSubmit?()
    }
}

private enum CodeInputFocus: Hashable {
    case code
}

#Preview("Code") {
    @Previewable @State var code = "MMWKYM2H78A"
    CodeInput(label: "Recovery code", value: $code, hint: "26 characters, from the paper you kept")
        .padding()
}
