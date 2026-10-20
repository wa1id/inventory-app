import SwiftUI
import InventoryAppModels

/// A settings line: label and current value (RN `SettingsRow`, 06 §12).
///
/// The icon, then a stock `LabeledContent`, so VoiceOver hears the value with the label
/// ("Household, Joined as Walid's iPhone") before opening it, and the value moves under the label
/// at large sizes. The icon sits in its own column beside the words rather than in a `Label`,
/// whose title column at the largest sizes was narrow enough to break "Household" inside the
/// word; here the words take the rest of the row and wrap between words. Put it in a
/// `NavigationLink` to open a screen, or use it as the label of a `DisclosureGroup` to expand in
/// place; a static fact (Version) stands alone.
struct SettingsRow: View {
    enum Tone: Sendable {
        case normal
        /// A value that needs attention (a failed backup).
        case signal
    }

    let label: String
    var value: String?
    var tone: Tone = .normal
    var glyph: Glyph?
    var identifier: String?

    /// The icon column, as wide as a list row's icon at the default size; it grows with the
    /// text up to 1.6 times (RN `inlineIconSize`), so rows keep their words in line.
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 28
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At the accessibility sizes the icon goes above the words, which then take the row's
        // whole width: beside it, "Household" was still wider than its column on a 375 pt phone
        // and broke inside the word. One tree either way (a layout swap).
        let shape = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        shape {
            if let glyph {
                Image(glyph: glyph)
                    .foregroundStyle(.secondary)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(width: min(iconColumn, 28 * 1.6))
                    .accessibilityHidden(true)
            }
            LabeledContent {
                if let value {
                    Text(verbatim: value)
                        .foregroundStyle(tone == .signal ? AnyShapeStyle(DesignColor.signal) : AnyShapeStyle(.secondary))
                }
            } label: {
                Text(verbatim: label)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: FeedbackText.settingsAccessibilityLabel(label: label, value: value)))
        .accessibilityIdentifierIfPresent(identifier)
    }
}

/// A labelled fact on the item screen: "Category" over "Tools" (RN `FactRow`).
struct FactRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label)
                .textRole(.factLabel)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension FactRow where Content == Text {
    /// A plain-text fact; notes keep their line breaks and can be selected.
    init(label: String, text: String) {
        self.label = label
        self.content = Text(verbatim: text)
    }
}

extension FactRow where Content == AnyView {
    /// A plain-text fact that can be selected and copied, as RN's `selectable` body text (notes).
    init(label: String, selectableText text: String) {
        self.label = label
        self.content = AnyView(Text(verbatim: text).textSelection(.enabled))
    }
}

#Preview("Settings") {
    @Previewable @State var expanded = false
    NavigationStack {
        Form {
            NavigationLink { Text(verbatim: "Household") } label: {
                SettingsRow(label: "Household", value: "Joined as Walid's iPhone", glyph: .server)
            }
            NavigationLink { Text(verbatim: "Backup") } label: {
                SettingsRow(label: "Backup", value: "Needs attention", tone: .signal, glyph: .backup)
            }
            SettingsRow(label: "Version", value: "0.2.0", glyph: .phone)
            DisclosureGroup(isExpanded: $expanded) {
                SettingsRow(label: "Schema", value: "v7")
            } label: {
                SettingsRow(label: "Technical details", glyph: .settings)
            }
            FactRow(label: "Category", text: "Tools")
        }
    }
}
