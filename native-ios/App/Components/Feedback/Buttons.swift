import SwiftUI
import InventoryAppModels

/// The RN `Button` variants as stock button styles (08 §10).
///
/// - `primary`: `.borderedProminent` in the ink tint, the only filled control on a screen.
/// - `secondary`: `.bordered`.
/// - `quiet`: `.borderless`.
/// - `destructive`: text in the destructive role, never filled; it always leads to a confirm.
enum ButtonVariant: Sendable, Hashable {
    case primary, secondary, quiet, destructive

    var role: ButtonRole? { self == .destructive ? .destructive : nil }
}

/// RN `size: 'md' | 'sm'`.
enum ButtonSize: Sendable, Hashable {
    case regular, small

    var controlSize: ControlSize { self == .small ? .small : .regular }
}

private struct ButtonVariantModifier: ViewModifier {
    let variant: ButtonVariant
    let size: ButtonSize

    func body(content: Content) -> some View {
        Group {
            switch variant {
            // The label is the page colour on ink: white in light mode, near black in dark mode,
            // where the ink tint is light (RN `onInk`).
            case .primary: content.buttonStyle(.borderedProminent).foregroundStyle(Color(uiColor: .systemBackground))
            case .secondary: content.buttonStyle(.bordered)
            case .quiet, .destructive: content.buttonStyle(.borderless)
            }
        }
        .controlSize(size.controlSize)
    }
}

extension View {
    /// Applies a variant's stock style and size to a `Button`.
    func buttonVariant(_ variant: ButtonVariant, size: ButtonSize = .regular) -> some View {
        modifier(ButtonVariantModifier(variant: variant, size: size))
    }
}

/// A button that can be busy (RN `Button` with `loading`).
///
/// While loading it keeps its label in place (no width jump, still announced), ignores presses,
/// and only after 150 ms (`Motion.delay.spinner`) shows a spinner, which replaces the leading
/// icon. It is not dimmed while busy, as in RN; the spinner is the busy cue. Labels wrap to two
/// lines at large sizes instead of clipping.
struct LoadingButton: View {
    let label: String
    var glyph: Glyph?
    var variant: ButtonVariant = .primary
    var size: ButtonSize = .regular
    var isLoading = false
    var isDisabled = false
    var fullWidth = false
    /// Defaults to the label; pass the item-specific form ("Move “Cordless drill”…").
    var accessibilityLabel: String?
    var accessibilityHint: String?
    var identifier: String?
    let action: () -> Void

    @State private var spinner = DelayedFlag(delay: .milliseconds(Motion.delay.spinner))

    var body: some View {
        Button(role: variant.role) {
            guard !isLoading else { return }
            action()
        } label: {
            HStack(spacing: 8) {
                if spinner.value {
                    ProgressView()
                        .controlSize(.small)
                        .tint(variant == .primary ? Color(uiColor: .systemBackground) : nil)
                } else if let glyph {
                    Image(glyph: glyph)
                }
                Text(verbatim: label)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .modifier(PrimaryLabelColor(isActive: variant == .primary && !isDisabled))
            .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonVariant(variant, size: size)
        .disabled(isDisabled)
        .allowsHitTesting(!isLoading)
        .accessibilityLabel(Text(verbatim: accessibilityLabel ?? label))
        .accessibilityHintIfPresent(accessibilityHint)
        .accessibilityIdentifierIfPresent(identifier)
        .onChange(of: isLoading, initial: true) { _, loading in spinner.setActive(loading) }
    }
}

/// The page colour on the ink fill of a primary button (RN `onInk`); other variants keep the
/// colour their stock style gives them (the tint, or red for destructive).
private struct PrimaryLabelColor: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.foregroundStyle(Color(uiColor: .systemBackground))
        } else {
            content
        }
    }
}

#Preview("Buttons") {
    VStack(alignment: .leading, spacing: 12) {
        LoadingButton(label: "Save", glyph: .check, action: {})
        LoadingButton(label: "Save", variant: .primary, isLoading: true, action: {})
        LoadingButton(label: "Move…", glyph: .move, variant: .secondary, size: .small, action: {})
        LoadingButton(label: "Not now", variant: .quiet, action: {})
        LoadingButton(label: "Delete", glyph: .trash, variant: .destructive, action: {})
        LoadingButton(label: "Disabled", variant: .primary, isDisabled: true, action: {})
        LoadingButton(label: "Save and add another", variant: .primary, fullWidth: true, action: {})
    }
    .padding()
}
