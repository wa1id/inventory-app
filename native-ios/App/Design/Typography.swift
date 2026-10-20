import SwiftUI

/// The RN type scale (src/ui/typography.ts) as system text styles under Dynamic Type (08 §6).
///
/// Every role scales with the system size. Only fixed-geometry text (tape, badges, stepper
/// digits) is capped, at the largest step that stays within RN's `maxFontSizeMultiplier`;
/// everything else wraps instead of clipping. The location line (`where`) is the same size as
/// the name above it: the answer is never smaller than the question.
enum TextRole: Sendable, CaseIterable {
    case display, title, whereCard, itemTitle, heading, code
    case name, `where`, body, section, label, meta, aside, caption, factLabel, badge
    case tapeS, tapeM, tapeL, stepper, stepperL

    var font: Font {
        switch self {
        case .display: .largeTitle.weight(.heavy)
        case .title: .title.bold()
        case .whereCard: .title.bold()
        case .itemTitle: .title2.bold()
        case .heading: .title3.bold()
        case .code: .title3.bold().monospacedDigit()
        case .name: .headline
        case .where: .body.weight(.medium)
        case .body: .body
        case .section: .callout.bold()
        case .label: .subheadline.weight(.semibold)
        case .meta: .subheadline.weight(.medium)
        case .aside: .subheadline.weight(.semibold).monospacedDigit()
        case .caption: .footnote.weight(.medium)
        case .factLabel: .footnote.bold()
        case .badge: .caption.bold().monospacedDigit()
        case .tapeS: .footnote.bold().monospacedDigit()
        case .tapeM: .callout.bold().monospacedDigit()
        case .tapeL: .title2.weight(.heavy).monospacedDigit()
        case .stepper: .body.weight(.heavy).monospacedDigit()
        case .stepperL: .title2.weight(.heavy).monospacedDigit()
        }
    }

    /// Letter spacing in points (RN `tracking`).
    var tracking: CGFloat {
        switch self {
        case .display: -0.4
        case .title: -0.3
        case .code: 1.5
        case .caption, .factLabel: 0.1
        case .tapeS: 0.9
        case .tapeM: 1.1
        case .tapeL: 1.8
        default: 0
        }
    }

    /// Headings announce as headers (RN `HEADER_VARIANTS`); the where card opts out.
    var isHeader: Bool {
        switch self {
        case .display, .title, .itemTitle, .heading: true
        default: false
        }
    }

    /// The largest Dynamic Type size fixed-geometry text grows to (08 §6: RN caps 1.3 → xxLarge,
    /// 1.5 and 1.6 → xxxLarge). Nil: scales all the way.
    var maximumSize: DynamicTypeSize? {
        switch self {
        case .badge: .xxLarge
        case .tapeS, .tapeM, .tapeL, .stepper, .stepperL: .xxxLarge
        default: nil
        }
    }
}

private struct TextRoleModifier: ViewModifier {
    let role: TextRole
    let header: Bool

    func body(content: Content) -> some View {
        content
            .font(role.font)
            .tracking(role.tracking)
            .dynamicTypeSize(...(role.maximumSize ?? .accessibility5))
            .accessibilityAddTraits(header ? .isHeader : [])
    }
}

extension View {
    /// Sets the font, tracking, size cap and header trait of a type role.
    /// - Parameter header: overrides the role's header trait (the where card's title-sized answer is not a heading).
    func textRole(_ role: TextRole, header: Bool? = nil) -> some View {
        modifier(TextRoleModifier(role: role, header: header ?? role.isHeader))
    }
}
