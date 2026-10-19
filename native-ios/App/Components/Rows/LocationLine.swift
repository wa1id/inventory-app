import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The answer to "where is it?": pip, "Space › Container", label tape (RN `LocationLine`,
/// 07 §4.4).
///
/// The only way a location is drawn, never smaller than the name above it. It never truncates:
/// each name wraps on its own and the tape moves to the next line whole. The drop zone is always
/// the tray and the words "Drop zone", never its stored teal or internal code. It is not an
/// element of its own: the row around it speaks it with `whereSpoken`.
struct LocationLine: View {
    enum Size: Sendable {
        /// Item rows: pip 12, the `where` type, a tape.
        case row
        /// The where card: pip 14, title type, no tape (an unnamed container shows its code).
        case card
        /// Search rows: pip 10, the `meta` type, a tape.
        case inline

        var role: TextRole {
            switch self {
            case .row: .where
            case .card: .whereCard
            case .inline: .meta
            }
        }

        var pip: CGFloat {
            switch self {
            case .row: 12
            case .card: 14
            case .inline: 10
            }
        }

        var showsTape: Bool { self != .card }
    }

    /// The space and container links of the where card.
    struct Links {
        var openSpace: () -> Void
        var openContainer: () -> Void
    }

    let place: RowPlace
    var size: Size = .row
    /// False for a container's own row in search, where only its space is the answer.
    var showsContainer = true
    /// On the camera: white text.
    var onCamera = false
    /// The card only: the names become underlined links.
    var links: Links?

    init(place: some PlaceLike, size: Size = .row, showsContainer: Bool = true, onCamera: Bool = false, links: Links? = nil) {
        self.place = RowPlace(place)
        self.size = size
        self.showsContainer = showsContainer
        self.onCamera = onCamera
        self.links = links
    }

    private var ink: Color { onCamera ? .white : .primary }
    private var quiet: Color { onCamera ? .white : .secondary }

    var body: some View {
        if PlaceRowText.isDropZone(place) {
            dropZone
        } else {
            WrappingHStack(horizontalSpacing: 6, verticalSpacing: 2) {
                SpacePip(color: place.spaceColor, size: size.pip)
                name(place.spaceName, link: links?.openSpace, hint: L10n.A11y.opensSpace, identifier: "where-space")
                if showsContainer {
                    Text(verbatim: "›")
                        .textRole(size.role, header: false)
                        .foregroundStyle(quiet)
                        .accessibilityHidden(true)
                    if let label = PlaceRowText.locationContainerLabel(place, showsTape: size.showsTape) {
                        name(label, link: links?.openContainer, hint: L10n.A11y.opensContainer, identifier: "where-container")
                    }
                    if size.showsTape {
                        Tape(code: place.containerShortCode, size: .small)
                    }
                }
            }
        }
    }

    /// The tray and "Drop zone", then " · not filed yet" except on the card, as one text so a
    /// wrap falls between words.
    private var dropZone: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(glyph: .inbox)
                .foregroundStyle(ink)
                .accessibilityHidden(true)
            Text(dropZoneText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textRole(size.role, header: false)
    }

    private var dropZoneText: AttributedString {
        var text = AttributedString(L10n.Where.dropZone)
        text.foregroundColor = ink
        if size != .card {
            var rest = AttributedString(L10n.Where.notFiledYet)
            rest.foregroundColor = quiet
            text += rest
        }
        return text
    }

    @ViewBuilder
    private func name(_ text: String, link: (() -> Void)?, hint: String, identifier: String) -> some View {
        if let link, size == .card {
            Button(action: link) {
                Text(verbatim: text)
                    .underline()
                    .textRole(size.role, header: false)
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isLink)
            .accessibilityRemoveTraits(.isButton)
            .accessibilityHint(Text(verbatim: hint))
            .accessibilityIdentifier(identifier)
        } else {
            Text(verbatim: text)
                .textRole(size.role, header: false)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Kept in": the answer to "where is it?" on the item screen, its largest text
/// (RN `WhereCard`, 07 §4.3).
///
/// The space and the container are each a link; the card itself is not pressable. The code is
/// the tape on the box, read letter by letter. Move sits on the card because moving changes this
/// answer; an item in the drop zone says so plainly and offers "File it…" as the main action.
struct WhereCard: View {
    let place: RowPlace
    /// The item's name, for "Move “Cordless drill”…"; empty when it has none yet.
    let name: String
    let onMove: () -> Void
    var links: LocationLine.Links?

    init(place: some PlaceLike, name: String, links: LocationLine.Links? = nil, onMove: @escaping () -> Void) {
        self.place = RowPlace(place)
        self.name = name
        self.links = links
        self.onMove = onMove
    }

    var body: some View {
        let copy = WhereCardCopy(place: place, name: name)
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: L10n.Where.keptIn)
                .textRole(.factLabel)
                .foregroundStyle(.secondary)
            LocationLine(place: place, size: .card, links: links)
            // The action sits at the end of the row, after the tape or the note; it moves under
            // them when they do not fit side by side.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    footerLead(copy)
                    Spacer(minLength: 0)
                    action(copy)
                }
                VStack(alignment: .leading, spacing: 12) {
                    footerLead(copy)
                    action(copy)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: L10n.A11y.whereItIs))
        .accessibilityIdentifier("where-card")
    }

    @ViewBuilder
    private func footerLead(_ copy: WhereCardCopy) -> some View {
        if copy.isDropZone {
            Text(verbatim: L10n.Where.notFiledNote)
                .textRole(.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Tape(code: place.containerShortCode, size: .medium, spoken: true)
        }
    }

    private func action(_ copy: WhereCardCopy) -> some View {
        LoadingButton(
            label: copy.actionTitle,
            glyph: .move,
            variant: copy.isDropZone ? .primary : .secondary,
            size: .small,
            accessibilityLabel: copy.actionAccessibilityLabel,
            identifier: copy.actionIdentifier,
            action: onMove
        )
    }
}

#Preview("Location") {
    let filed = RowPlace(containerId: "c1", containerName: "Tool chest", containerShortCode: "CAB-J92R", spaceId: "s1", spaceName: "Garage", spaceColor: "#5B8DEF")
    let unnamed = RowPlace(containerId: "c2", containerName: nil, containerShortCode: "BOX-4F2A", spaceId: "s1", spaceName: "A very long space name that wraps", spaceColor: "#E4572E")
    let waiting = RowPlace(containerId: DropZone.containerId, containerName: "Drop zone", containerShortCode: "DROP-ZONE", spaceId: DropZone.spaceId, spaceName: "Drop zone", spaceColor: "#0F9BB0")
    List {
        LocationLine(place: filed)
        LocationLine(place: unnamed)
        LocationLine(place: waiting)
        LocationLine(place: filed, size: .inline, showsContainer: false)
        WhereCard(place: filed, name: "Drill", links: .init(openSpace: {}, openContainer: {}), onMove: {})
        WhereCard(place: waiting, name: "", onMove: {})
    }
}
