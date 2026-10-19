import InventoryCore

// RN: src/ui/navigation.ts:56-96. What a screen opened for a result hands back to the one
// that opened it (06 §3.4). The photo the camera returns is a `StoredImage`.

/// The item moved (or filed) from one container to another (RN `MoveResult`).
public struct MoveResult: Sendable, Hashable {
    public var itemId: String
    public var from: String
    public var to: String
    /// The item's `updatedAt` after the move, for an Undo that does not conflict with itself.
    public var updatedAt: Int64
    /// A filing run only: the drop zone's ids as read right after the move, so the run's next
    /// item agrees with the toast. Nil when that read failed or outside a run.
    public var waiting: [String]?

    public init(itemId: String, from: String, to: String, updatedAt: Int64, waiting: [String]? = nil) {
        self.itemId = itemId
        self.from = from
        self.to = to
        self.updatedAt = updatedAt
        self.waiting = waiting
    }
}

/// The container just created, with what the place picker shows of it, so the picker need
/// not read it back (RN `NewContainerResult`).
public struct NewContainerResult: Sendable, Hashable {
    public var containerId: String
    public var name: String?
    public var shortCode: String
    public var visualType: ContainerVisualType
    public var spaceId: String

    public init(containerId: String, name: String?, shortCode: String, visualType: ContainerVisualType, spaceId: String) {
        self.containerId = containerId
        self.name = name
        self.shortCode = shortCode
        self.visualType = visualType
        self.spaceId = spaceId
    }

    /// The result for a container the repository just created.
    public init(_ container: Container) {
        self.init(
            containerId: container.id,
            name: container.name,
            shortCode: container.shortCode,
            visualType: container.visualType,
            spaceId: container.spaceId
        )
    }
}

/// The space just created (RN `NewSpaceResult`).
public struct NewSpaceResult: Sendable, Hashable {
    public var spaceId: String
    public var name: String

    public init(spaceId: String, name: String) {
        self.spaceId = spaceId
        self.name = name
    }

    /// The result for a space the repository just created.
    public init(_ space: Space) {
        self.init(spaceId: space.id, name: space.name)
    }
}
