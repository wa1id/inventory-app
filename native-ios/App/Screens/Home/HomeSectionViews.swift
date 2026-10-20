import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

// The pieces of the three tab roots' lists (Home, Spaces, Drop zone) that no other screen
// draws: the line under the large title, Home's section headers with their totals, and the
// drop-zone card (RN TabRootHeader's subtitle, Sheet's `Section`, TotalLine.tsx,
// DropZoneCard.tsx).

/// The first list row under a tab root's large title (RN `TabRootHeader`'s subtitle): plain text
/// on the page, not in a cell, lined up with the title. It scrolls away with the list.
struct HomeTitleNote<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            // Clear of the top edge effect under the large title.
            .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 4, trailing: 4))
        }
        .listSectionSpacing(.compact)
    }
}

/// Home's two lines under the title: the household at a glance, then where the data lives,
/// always (RN app/(tabs)/index.tsx:421-449). Joined and the home server not answering, the
/// second line and its icon turn signal.
struct HomeSummaryLines: View {
    let summary: String?
    let whereLine: String
    let paired: Bool
    let reconnecting: Bool

    var body: some View {
        if let summary {
            Text(verbatim: summary)
                .textRole(.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(glyph: paired ? .server : .phone)
                .font(TextRole.caption.font)
                // An inline icon grows with the text up to 1.6 times (RN `inlineIconSize`).
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityHidden(true)
            Text(verbatim: whereLine)
                .textRole(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(reconnecting ? AnyShapeStyle(DesignColor.signal) : AnyShapeStyle(.secondary))
    }
}

/// A section's header (RN Sheet `Section`: "Recently added  12"), with what RN drew around the
/// title outside the sheet: the results summary above it (not a live region: it changes as she
/// types) and the totals line under it.
struct HomeSectionHeader: View {
    var summary: String?
    var title: String?
    var count: Int?
    var totals: [HomeList.NameTotal] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary {
                Text(verbatim: summary)
                    .textRole(.meta)
                    .foregroundStyle(Color.secondary)
                    .padding(.bottom, 4)
            }
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: title)
                        .textRole(.section, header: true)
                        // Ink, as RN's section titles; the list draws headers in a quieter colour.
                        .foregroundStyle(Color.primary)
                    if let count {
                        Text(verbatim: "\(count)")
                            .textRole(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
            if !totals.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(totals, id: \.self) { total in
                        HomeTotalLine(text: HomeTotalLineText(total))
                    }
                }
                .padding(.top, 2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textCase(nil)
    }
}

/// "“AA batteries”: ×14 in 2 places": how many there are when they are kept in two boxes
/// (RN TotalLine.tsx). Plain text, read as one sentence.
struct HomeTotalLine: View {
    let text: HomeTotalLineText

    var body: some View {
        Text(attributed)
            .textRole(.meta)
            .foregroundStyle(Color.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: text.accessibilityLabel))
    }

    private var attributed: AttributedString {
        var line = AttributedString(text.name + " ")
        var count = AttributedString(text.count)
        count.font = TextRole.aside.font
        count.foregroundColor = text.isNoneLeft ? DesignColor.signal : .primary
        line += count
        line += AttributedString(" " + text.places)
        return line
    }
}

/// Home's reminder that some items are waiting for a place (RN DropZoneCard.tsx): the text
/// beside a small overlapping stack of the first three waiting photos, then "Sort the drop
/// zone" and "Quick Snap" side by side. The card itself is not a button, so Quick Snap is never
/// a button inside a button; at large text the photos go above the text.
struct HomeDropZoneCard: View {
    /// The waiting items, newest first.
    let items: [ItemWithContext]
    let count: Int
    let onSort: () -> Void
    let onQuickSnap: () -> Void

    /// How many waiting items show a photo (RN `THUMBS`).
    static let thumbCount = 3

    private let layout = LayoutScale()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if layout.isStacked {
                thumbs
                text
            } else {
                HStack(alignment: .center, spacing: 12) {
                    text.frame(maxWidth: .infinity, alignment: .leading)
                    thumbs
                }
            }
            AdaptiveStack(horizontalAlignment: .leading, spacing: 8) {
                LoadingButton(label: L10n.Home.DropZone.sort, variant: .secondary, size: .small, identifier: "drop-zone-open", action: onSort)
                LoadingButton(label: L10n.Home.DropZone.quickSnap, glyph: .layers, variant: .quiet, size: .small, identifier: "quick-snap", action: onQuickSnap)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drop-zone-card")
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: L10n.Home.DropZone.title(count: count))
                .textRole(.section, header: true)
            Text(verbatim: L10n.Home.DropZone.body)
                .textRole(.meta)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var thumbs: some View {
        HStack(spacing: -16) {
            ForEach(items.prefix(Self.thumbCount)) { item in
                Thumb(uri: item.photoThumbUri ?? item.photoUri, size: 40)
                    // The 2 pt ring in the card's colour that sets one photo off the one it overlaps.
                    .padding(2)
                    .background(
                        RoundedRectangle(cornerRadius: DesignMetrics.thumbRadius + 2, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
            }
        }
        .padding(-2)
        .accessibilityHidden(true)
    }
}

/// A state that fills the screen in place of a list (a skeleton, an empty or error state),
/// scrolling once it does not fit, so its buttons stay reachable at the largest text sizes
/// (UI-KIT §4), with an optional banner above it. An empty or error state is centred while it
/// fits; a skeleton sits at the top, where the rows will be. Pull to refresh and the tab's scroll
/// to top work on it too.
struct HomeFillingState<Banner: View, Content: View>: View {
    enum Placement {
        case center, top
    }

    var placement: Placement = .center
    var banner: Banner?
    @ViewBuilder var content: Content

    init(placement: Placement = .center, banner: Banner?, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.banner = banner
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    if let banner {
                        banner
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous)
                                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                            )
                            .padding(.horizontal)
                    }
                    content
                        .frame(maxWidth: .infinity, maxHeight: placement == .center ? .infinity : nil)
                    if placement == .top { Spacer(minLength: 0) }
                }
                .padding(.top, placement == .top ? 8 : 0)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }
}

extension HomeFillingState where Banner == EmptyView {
    init(placement: Placement = .center, @ViewBuilder content: () -> Content) {
        self.init(placement: placement, banner: nil, content: content)
    }
}

extension View {
    /// A status (skeleton, empty or error state) as a list row: on the page, not in a cell.
    func homeStateRow() -> some View {
        // Its full height: a list row would otherwise cut a state view's text to a line.
        fixedSize(horizontal: false, vertical: true)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
    }
}
