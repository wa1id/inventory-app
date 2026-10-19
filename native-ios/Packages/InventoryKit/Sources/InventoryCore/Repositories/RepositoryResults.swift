// RN: result shapes of src/repositories/{spaces,containers,items}.ts that are
// not domain entities. Codable keys are the TS names (the household server
// returns `orphanedPhotoUris` in delete responses).

/// What deleting a space would take with it, for the confirm dialog (RN `SpaceDeletionImpact`).
public struct SpaceDeletionImpact: Sendable, Hashable, Codable {
    public var containerCount: Int
    public var itemCount: Int
    public var photoCount: Int
    public var qrBindingCount: Int

    public init(containerCount: Int, itemCount: Int, photoCount: Int, qrBindingCount: Int) {
        self.containerCount = containerCount
        self.itemCount = itemCount
        self.photoCount = photoCount
        self.qrBindingCount = qrBindingCount
    }
}

/// What deleting a container would take with it (RN `ContainerDeletionImpact`).
public struct ContainerDeletionImpact: Sendable, Hashable, Codable {
    public var itemCount: Int
    public var photoCount: Int
    public var hasQrBinding: Bool

    public init(itemCount: Int, photoCount: Int, hasQrBinding: Bool) {
        self.itemCount = itemCount
        self.photoCount = photoCount
        self.hasQrBinding = hasQrBinding
    }
}

/// The outcome of deleting a space, container or item (RN `{ deleted, orphanedPhotoUris }`).
public struct DeletionResult: Sendable, Hashable, Codable {
    /// Whether a row was deleted (`false` when it was already gone).
    public var deleted: Bool
    /// Stored photo URIs (full and thumbnail, `NULL`s dropped) whose rows are gone.
    /// The caller deletes the files; resolve them through `PhotoPathResolver` first.
    public var orphanedPhotoUris: [String]

    public init(deleted: Bool, orphanedPhotoUris: [String]) {
        self.deleted = deleted
        self.orphanedPhotoUris = orphanedPhotoUris
    }

    /// Nothing was deleted.
    public static let notDeleted = DeletionResult(deleted: false, orphanedPhotoUris: [])
}
