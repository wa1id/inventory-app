import SwiftUI
import InventoryCore
import InventoryStrings

/// Yellow label tape: a container's code looking like the label on the box (RN `Tape`).
///
/// The one loud thing in the design (U2). The code is shown exactly as stored, on one line,
/// never truncated or wrapped; in a wrapping row it moves to the next line whole. Its digits are
/// capped at `xxxLarge` (fixed geometry). Decorative unless `spoken`, when it is its own element
/// read letter by letter: "label D R W, 7 K 2 M".
struct Tape: View {
    enum Size: Sendable {
        case small, medium, large, badge

        var role: TextRole {
            switch self {
            case .small: .tapeS
            case .medium: .tapeM
            case .large: .tapeL
            case .badge: .badge
            }
        }

        var padding: EdgeInsets {
            switch self {
            case .small: EdgeInsets(top: 4, leading: 6, bottom: 3, trailing: 6)
            case .medium: EdgeInsets(top: 5, leading: 8, bottom: 4, trailing: 8)
            case .large: EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12)
            case .badge: EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
            }
        }

        var radius: CGFloat {
            switch self {
            case .small, .medium: 3
            case .large: 4
            case .badge: 10
            }
        }
    }

    let code: String
    var size: Size = .small
    var spoken = false

    var body: some View {
        Text(verbatim: code)
            .textRole(size.role)
            .foregroundStyle(Color(.tapeInk))
            .lineLimit(1)
            .fixedSize()
            .padding(size.padding)
            .frame(minWidth: size == .badge ? 20 : nil, minHeight: size == .badge ? 20 : nil)
            .background(
                RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                    .fill(Color(.tape))
                    // A faint bevel, as the RN tape's inset shadow.
                    .overlay(
                        RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                            .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
                    )
            )
            .modifier(TapeAccessibility(code: code, spoken: spoken))
    }
}

private struct TapeAccessibility: ViewModifier {
    let code: String
    let spoken: Bool

    func body(content: Content) -> some View {
        if spoken {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.A11y.labelCode(spelled: spellCode(code)))
        } else {
            content.accessibilityHidden(true)
        }
    }
}

/// The household mark: an ink box with a strip of label tape across it (RN `Mark`). Decorative.
/// Sizes 52 × 46 (radius 10) and 72 × 64 (radius 14); the tape sits at 36 % from the top, 30 %
/// tall, inset 20 % on each side, radius 3.
struct BrandMark: View {
    enum Size: Sendable {
        case regular, large

        var box: CGSize { self == .regular ? CGSize(width: 52, height: 46) : CGSize(width: 72, height: 64) }
        var radius: CGFloat { self == .regular ? 10 : 14 }
    }

    var size: Size = .regular

    var body: some View {
        let box = size.box
        RoundedRectangle(cornerRadius: size.radius, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: box.width, height: box.height)
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(.tape))
                    .frame(width: box.width * 0.6, height: box.height * 0.3)
                    .offset(x: box.width * 0.2, y: box.height * 0.36)
            }
            .accessibilityHidden(true)
    }
}

#Preview("Tape and mark") {
    VStack(alignment: .leading, spacing: 16) {
        HStack {
            Tape(code: "DRW-7K2M")
            Tape(code: "DRW-7K2M", size: .medium, spoken: true)
            Tape(code: "3", size: .badge)
        }
        Tape(code: "CAB-J92R", size: .large)
        HStack(spacing: 24) {
            BrandMark()
            BrandMark(size: .large)
        }
    }
    .padding()
}
