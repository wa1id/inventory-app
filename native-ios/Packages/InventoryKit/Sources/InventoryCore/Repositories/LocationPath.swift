// RN: src/repositories/search.ts:293-298 (`formatLocationPath`).

/// The `Space > Container` path shown on an item result; the drop zone shows just its space name.
public func formatLocationPath(_ item: ItemWithContext) -> String {
    if item.containerId == DropZone.containerId { return item.spaceName }
    return "\(item.spaceName) > \(item.containerName ?? item.containerShortCode)"
}
