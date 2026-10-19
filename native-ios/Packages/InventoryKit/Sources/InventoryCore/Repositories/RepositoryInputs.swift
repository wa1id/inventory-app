// RN: the input types of src/repositories/{spaces,containers,items}.ts. Fields
// keep the TS names and optionality: `nil` stands for an omitted (`undefined`)
// field, and `FieldUpdate` for the `string | null` patch fields where omitting
// and clearing differ. Both the local and the household repositories take these.

/// A new space (RN `CreateSpaceInput`). The repository trims `name` but does not validate it.
public struct CreateSpaceInput: Sendable, Hashable {
    public var name: String
    public var icon: String
    public var color: String

    public init(name: String, icon: String, color: String) {
        self.name = name
        self.icon = icon
        self.color = color
    }
}

/// A space patch (RN `UpdateSpaceInput`, `Partial<CreateSpaceInput>`); `nil` keeps the stored value.
///
/// A provided blank `name` is saved as `''` (01 §12.2).
public struct UpdateSpaceInput: Sendable, Hashable {
    public var name: String?
    public var icon: String?
    public var color: String?

    public init(name: String? = nil, icon: String? = nil, color: String? = nil) {
        self.name = name
        self.icon = icon
        self.color = color
    }
}

/// A new container (RN `CreateContainerInput`). A blank or missing `name` is stored as `NULL`.
public struct CreateContainerInput: Sendable, Hashable {
    public var spaceId: String
    public var name: String?
    public var visualType: ContainerVisualType

    public init(spaceId: String, name: String? = nil, visualType: ContainerVisualType) {
        self.spaceId = spaceId
        self.name = name
        self.visualType = visualType
    }
}

/// A container patch (RN `UpdateContainerInput`).
///
/// `name`: `.unchanged` keeps it; `.clear` or a blank `.set` stores `NULL`.
/// The short code never changes, even when `visualType` does.
public struct UpdateContainerInput: Sendable, Hashable {
    public var name: FieldUpdate<String>
    public var visualType: ContainerVisualType?
    public var spaceId: String?

    public init(name: FieldUpdate<String> = .unchanged, visualType: ContainerVisualType? = nil, spaceId: String? = nil) {
        self.name = name
        self.visualType = visualType
        self.spaceId = spaceId
    }
}

/// The photo attached to a new or updated item (RN `ItemDraft['photo']`).
public struct ItemPhotoInput: Sendable, Hashable {
    /// Row id to use on create; the repository assigns one when `nil`, and always on update.
    /// The home server passes its R2 object id.
    public var id: String?
    public var uri: String
    public var thumbUri: String?
    public var width: Int?
    public var height: Int?
    public var byteSize: Int?

    public init(
        id: String? = nil,
        uri: String,
        thumbUri: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        byteSize: Int? = nil
    ) {
        self.id = id
        self.uri = uri
        self.thumbUri = thumbUri
        self.width = width
        self.height = height
        self.byteSize = byteSize
    }
}

/// A new item with its optional photo and tags, written atomically (RN `ItemDraft`).
public struct ItemDraft: Sendable, Hashable {
    public var containerId: String
    /// `nil` when the item has no name yet (fast capture writes the row before
    /// recognition); stored as `''`. A provided blank name is rejected.
    public var name: String?
    /// Trimmed; blank or `nil` is stored as `NULL`.
    public var category: String?
    /// Defaults to 1; must be 0 or more.
    public var quantity: Int?
    /// Trimmed; blank or `nil` is stored as `NULL`.
    public var notes: String?
    /// Trimmed, deduplicated by their folded form; the first spelling ever saved names a tag.
    public var tags: [String]?
    public var photo: ItemPhotoInput?

    public init(
        containerId: String,
        name: String? = nil,
        category: String? = nil,
        quantity: Int? = nil,
        notes: String? = nil,
        tags: [String]? = nil,
        photo: ItemPhotoInput? = nil
    ) {
        self.containerId = containerId
        self.name = name
        self.category = category
        self.quantity = quantity
        self.notes = notes
        self.tags = tags
        self.photo = photo
    }
}

/// An item patch (RN `UpdateItemInput`); `nil` and `.unchanged` keep the stored value.
public struct UpdateItemInput: Sendable, Hashable {
    public var containerId: String?
    /// A provided blank name is rejected; an item that is already unnamed stays editable.
    public var name: String?
    public var category: FieldUpdate<String>
    public var quantity: Int?
    public var notes: FieldUpdate<String>
    /// Replaces every tag link; `[]` clears them.
    public var tags: [String]?
    /// `.clear` deletes the photo rows; `.set` replaces them with a new row (a new id, any `id` ignored).
    public var photo: FieldUpdate<ItemPhotoInput>
    /// Optimistic lock: the row must still have this `updatedAt`, or the write throws
    /// ``ConflictError`` and changes nothing.
    public var expectedUpdatedAt: Int64?

    public init(
        containerId: String? = nil,
        name: String? = nil,
        category: FieldUpdate<String> = .unchanged,
        quantity: Int? = nil,
        notes: FieldUpdate<String> = .unchanged,
        tags: [String]? = nil,
        photo: FieldUpdate<ItemPhotoInput> = .unchanged,
        expectedUpdatedAt: Int64? = nil
    ) {
        self.containerId = containerId
        self.name = name
        self.category = category
        self.quantity = quantity
        self.notes = notes
        self.tags = tags
        self.photo = photo
        self.expectedUpdatedAt = expectedUpdatedAt
    }
}
