import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// A space: its tile, its name and how much is in it (RN `SpaceRow`, 07 §4.5).
struct SpaceRow: View {
    let space: SpaceWithCounts
    /// 56 on the Spaces tab, 48 in search results.
    var tileSize: CGFloat = 56
    /// Search terms to mark in the name.
    var terms: [String] = []
    let onPress: () -> Void

    var body: some View {
        ListRow(
            action: onPress,
            showsChevron: true,
            minHeight: tileSize,
            accessibilityLabel: PlaceRowText.spaceAccessibilityLabel(name: space.name, containers: space.containerCount, items: space.itemCount),
            identifier: PlaceRowText.spaceIdentifier(space.id)
        ) {
            SpaceTile(icon: space.icon, color: space.color, size: tileSize)
        } content: {
            PlaceName(name: space.name, terms: terms)
            Text(verbatim: PlaceRowText.spaceCounts(containers: space.containerCount, items: space.itemCount))
                .textRole(.meta)
                .foregroundStyle(.secondary)
        }
    }
}

/// A container: its type, its name followed by its label tape (RN `ContainerRow`, 07 §4.5).
/// An unnamed one is called what its own screen calls it ("Unnamed bag"), quietly.
struct ContainerRow: View {
    let container: ContainerRowData
    var context: ContainerRowContext = .space
    var terms: [String] = []
    let onPress: () -> Void

    var body: some View {
        ListRow(
            action: onPress,
            showsChevron: true,
            minHeight: 48,
            accessibilityLabel: PlaceRowText.containerAccessibilityLabel(container),
            identifier: PlaceRowText.containerIdentifier(container.id)
        ) {
            TypeTile(type: container.visualType, size: 48)
        } content: {
            WrappingHStack(horizontalSpacing: 8, verticalSpacing: 2) {
                if let name = container.name {
                    PlaceName(name: name, terms: terms)
                } else {
                    Text(verbatim: PlaceRowText.containerLabel(name: nil, visualType: container.visualType))
                        .textRole(.name)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Tape(code: container.shortCode, size: .small)
            }
            switch context {
            case .space:
                Text(verbatim: PlaceRowText.containerMeta(itemCount: container.itemCount, hasLabel: container.hasLabel))
                    .textRole(.meta)
                    .foregroundStyle(.secondary)
            case .search:
                if let spaceName = container.spaceName, !spaceName.isEmpty {
                    LocationLine(
                        place: RowPlace(
                            containerId: container.id,
                            containerName: container.name,
                            containerShortCode: container.shortCode,
                            spaceId: container.spaceId ?? "",
                            spaceName: spaceName,
                            spaceColor: container.spaceColor ?? ""
                        ),
                        size: .inline,
                        showsContainer: false
                    )
                }
            }
        } aside: {
            if context == .search {
                Text(verbatim: L10n.Entities.contents(count: container.itemCount))
                    .textRole(.meta)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A space or container that matched a search, drawn as everywhere else by joining the hit with
/// the full lists (RN `PlaceRow`). When the join is missing the hit's own title and subtitle
/// show, so a row is never blank.
struct PlaceRow: View {
    let hit: LocationSearchResult
    /// `spaces.listWithCounts()` by id.
    let spaces: [String: SpaceWithCounts]
    /// `containers.listAllWithSpace()` by id.
    let containers: [String: ContainerWithSpace]
    var terms: [String] = []
    let onPress: () -> Void

    var body: some View {
        Group {
            switch PlaceRowContent.resolve(hit, spaces: spaces, containers: containers) {
            case .space(let space):
                SpaceRow(space: space, tileSize: 48, terms: terms, onPress: onPress)
            case .container(let container):
                ContainerRow(container: container, context: .search, terms: terms, onPress: onPress)
            case .hit(let hit):
                ListRow(
                    action: onPress,
                    showsChevron: true,
                    minHeight: 48,
                    accessibilityLabel: PlaceRowText.hitAccessibilityLabel(hit),
                    identifier: PlaceRowText.placeIdentifier(hit.id)
                ) {
                    TypeTile(type: .other, size: 48)
                } content: {
                    PlaceName(name: hit.title, terms: terms)
                    Text(verbatim: hit.subtitle)
                        .textRole(.meta)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A place's name, with the search terms marked when there are any.
private struct PlaceName: View {
    let name: String
    let terms: [String]

    var body: some View {
        HighlightedText(text: name, terms: terms)
            .textRole(.name)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("Place rows") {
    let spaces = Dictionary(uniqueKeysWithValues: ComponentsFixtures.spaces.map { ($0.id, $0) })
    let containers = Dictionary(uniqueKeysWithValues: ComponentsFixtures.containers.map { ($0.id, $0) })
    List {
        SpaceRow(space: ComponentsFixtures.spaces[0], onPress: {})
        SpaceRow(space: ComponentsFixtures.spaces[2], tileSize: 48, terms: ["loft"], onPress: {})
        ContainerRow(container: ContainerRowData(id: "c1", name: "Tool chest", shortCode: "CAB-J92R", visualType: .cabinet, itemCount: 7, qrToken: "t"), onPress: {})
        ContainerRow(container: ContainerRowData(id: "c2", name: nil, shortCode: "BIN-4F2A", visualType: .bin, itemCount: 0), onPress: {})
        PlaceRow(hit: LocationSearchResult(kind: .container, id: "c-drawer", title: "", subtitle: "", spaceId: "s-garage", itemCount: 1), spaces: spaces, containers: containers, terms: ["screws"], onPress: {})
        PlaceRow(hit: LocationSearchResult(kind: .space, id: "s-new", title: "Hall", subtitle: "Space", spaceId: "s-new", itemCount: 0), spaces: spaces, containers: containers, onPress: {})
    }
}
#endif
