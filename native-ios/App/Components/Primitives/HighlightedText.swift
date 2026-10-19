import SwiftUI
import InventoryAppModels

/// Text with the search terms marked, so a result shows why it matched (RN `Highlighted`,
/// src/ui/components/AppText.tsx). Matches get the `SearchMark` background with primary text;
/// what VoiceOver reads is the plain text. Only terms of two or more characters count, as on
/// the desk (``TextHighlight``).
struct HighlightedText: View {
    let text: String
    let terms: [String]

    var body: some View {
        Text(Self.attributed(text, terms: terms))
    }

    /// The text with every match on the mark colour.
    static func attributed(_ text: String, terms: [String]) -> AttributedString {
        var result = AttributedString()
        for (index, part) in TextHighlight.split(text, terms: terms).enumerated() where !part.isEmpty {
            var piece = AttributedString(part)
            if index % 2 == 1 {
                piece.backgroundColor = Color(.searchMark)
                piece.foregroundColor = .primary
            }
            result += piece
        }
        return result
    }
}

#Preview {
    VStack(alignment: .leading) {
        HighlightedText(text: "Spare batteries AA", terms: ["batt", "aa"]).font(.headline)
        HighlightedText(text: "USB-C (2m)", terms: ["c", "(2m)"]).font(.headline)
    }
    .padding()
}
