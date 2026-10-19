import InventoryCore
import InventoryServices
import InventoryStrings

// RN: src/ui/add/addSheet.ts. The Add sheet's logic that needs no screen: where its state
// starts, which places it offers, and how it names the place it saves to (06 §10, 07 §2.8).

/// The photo of the item being added: stored on this phone, not yet anyone's (RN `AddPhoto`).
public struct AddPhoto: Sendable, Hashable {
    public var uri: String
    public var thumbUri: String?
    public var width: Int?
    public var height: Int?
    public var byteSize: Int?

    public init(uri: String, thumbUri: String? = nil, width: Int? = nil, height: Int? = nil, byteSize: Int? = nil) {
        self.uri = uri
        self.thumbUri = thumbUri
        self.width = width
        self.height = height
        self.byteSize = byteSize
    }

    /// The photo the camera handed back (RN `photoFromStored`).
    public init(_ stored: StoredImage) {
        self.init(uri: stored.uri, thumbUri: stored.thumbUri, width: stored.width, height: stored.height, byteSize: stored.byteSize)
    }

    /// What `items.create` stores with the item.
    var input: ItemPhotoInput {
        ItemPhotoInput(uri: uri, thumbUri: thumbUri, width: width, height: height, byteSize: byteSize)
    }
}

/// How the Add sheet was opened, every field optional (RN `AddParams`, the `/item/new` route
/// params): "Add here" sets `containerId`, Home's "Add “q”…" sets `name`, single-mode capture
/// sets the photo fields.
public struct AddParams: Sendable, Hashable {
    public var containerId: String?
    public var name: String?
    public var photoUri: String?
    public var photoThumbUri: String?
    public var photoWidth: String?
    public var photoHeight: String?
    public var photoBytes: String?

    public init(
        containerId: String? = nil,
        name: String? = nil,
        photoUri: String? = nil,
        photoThumbUri: String? = nil,
        photoWidth: String? = nil,
        photoHeight: String? = nil,
        photoBytes: String? = nil
    ) {
        self.containerId = containerId
        self.name = name
        self.photoUri = photoUri
        self.photoThumbUri = photoThumbUri
        self.photoWidth = photoWidth
        self.photoHeight = photoHeight
        self.photoBytes = photoBytes
    }

    /// The params the capture screen opens Add with after storing a photo nobody waited for.
    public init(containerId: String?, photo: StoredImage) {
        self.init(
            containerId: containerId,
            photoUri: photo.uri,
            photoThumbUri: photo.thumbUri,
            photoWidth: String(photo.width),
            photoHeight: String(photo.height),
            photoBytes: photo.byteSize.map { String($0) }
        )
    }
}

/// A draft as the sheet restores it (RN `AddDraftState`).
public struct AddDraftState: Sendable, Hashable {
    public var values: ItemFormValues
    /// `DropZone.containerId` for the drop zone.
    public var placeId: String
    /// The container picked in the place step, for when it is not in the sheet's own list.
    public var picked: PlaceOption?
    public var photo: AddPhoto?
    public var suggestion: SuggestionState
    public var showMore: Bool

    public init(values: ItemFormValues, placeId: String, picked: PlaceOption?, photo: AddPhoto?, suggestion: SuggestionState, showMore: Bool) {
        self.values = values
        self.placeId = placeId
        self.picked = picked
        self.photo = photo
        self.suggestion = suggestion
        self.showMore = showMore
    }
}

/// The draft kept between openings, with when it was written (RN `AddDraft`).
public struct AddDraft: Sendable, Hashable {
    public var state: AddDraftState
    /// Epoch milliseconds.
    public var savedAt: Int64

    public init(state: AddDraftState, savedAt: Int64) {
        self.state = state
        self.savedAt = savedAt
    }
}

/// Where the sheet starts (RN `AddInitialState`).
public struct AddInitialState: Sendable, Hashable {
    public var state: AddDraftState
    /// The state came from a draft: say so, and offer to clear it.
    public var restored: Bool
    /// Recognition has to be started on arrival (a fresh photo, or one cut off).
    public var recognize: Bool

    public init(state: AddDraftState, restored: Bool, recognize: Bool) {
        self.state = state
        self.restored = restored
        self.recognize = recognize
    }
}

/// One row of "Where it goes" (RN `WhereEntry`). ``AddSheetRules/whereEntries(param:recentIds:options:selectedId:picked:maxRecent:)``
/// never lists the same place twice, so ``id`` identifies a row.
public enum WhereEntry: Sendable, Hashable, Identifiable {
    /// Why a container row is listed.
    public enum Source: Sendable, Hashable {
        /// The container the sheet was opened for.
        case param
        /// One of this phone's recent places.
        case recent
        /// Picked from the full list (or selected though not listed otherwise).
        case picked
    }

    case dropZone
    case container(PlaceOption, source: Source)

    /// The container id the entry saves to (RN `entryId`).
    public var id: String {
        switch self {
        case .dropZone: DropZone.containerId
        case .container(let option, _): option.id
        }
    }
}

/// The place a save goes to (RN `ResolvedPlace`).
public struct ResolvedPlace: Sendable, Hashable {
    /// Where the item is saved.
    public var id: String
    /// Its details; nil for the drop zone and while they load.
    public var option: PlaceOption?

    public init(id: String, option: PlaceOption?) {
        self.id = id
        self.option = option
    }

    public var isDropZone: Bool { EntityText.same(id, DropZone.containerId) }
}

/// The Add sheet's rules (RN `src/ui/add/addSheet.ts`). Not named `AddSheet`, which is the
/// name the SwiftUI sheet takes.
public enum AddSheetRules {
    /// Recent places shown under "Where it goes"; the picker shows more (RN `MAX_RECENT_WHERE`).
    public static let maxRecentWhere = 3

    /// A route param as a positive whole number, else nil (RN `toPositiveInt`, JS `Number()`).
    public static func toPositiveInt(_ value: String?) -> Int? {
        guard let value, !value.isEmpty, let number = jsNumber(value.jsTrimmed()), number.isFinite,
              number.rounded(.towardZero) == number, number > 0
        else { return nil }
        return Int(exactly: number)
    }

    /// The photo single-mode capture stored before opening the sheet (RN `photoFromParams`).
    public static func photoFromParams(_ params: AddParams) -> AddPhoto? {
        guard let uri = params.photoUri, !uri.isEmpty else { return nil }
        return AddPhoto(
            uri: uri,
            thumbUri: params.photoThumbUri.flatMap { $0.isEmpty ? nil : $0 },
            width: toPositiveInt(params.photoWidth),
            height: toPositiveInt(params.photoHeight),
            byteSize: toPositiveInt(params.photoBytes)
        )
    }

    /// Both files of a photo, so the thumbnail is never left behind (RN `photoFiles`).
    public static func photoFiles(_ photo: AddPhoto?) -> [String?] {
        guard let photo else { return [] }
        return [photo.uri, photo.thumbUri]
    }

    /// Whether Category, Tags or Notes hold anything; they open "More details" (RN `hasDetails`).
    public static func hasDetails(_ values: ItemFormValues) -> Bool {
        [values.category, values.tags, values.notes].contains(where: EntityText.hasText)
    }

    /// Whether the sheet holds anything worth keeping or asking about: typing, a quantity other
    /// than the default, or a photo. The place alone is not (RN `formHasContent`).
    public static func formHasContent(_ values: ItemFormValues, photo: AddPhoto?, empty: ItemFormValues = .empty) -> Bool {
        photo != nil
            || EntityText.hasText(values.name)
            || hasDetails(values)
            || !EntityText.same(values.quantity.jsTrimmed(), empty.quantity)
    }

    /// Where the sheet starts (RN `initialAddState`). Params win: a container, a name from
    /// search or a photo from the camera each mean a new item. Only a plain open restores a
    /// draft; one cut off while recognising starts again if it has a photo.
    public static func initialState(params: AddParams, draft: AddDraftState?, empty: ItemFormValues = .empty) -> AddInitialState {
        let opened = [params.containerId, params.name, params.photoUri].contains { !($0 ?? "").isEmpty }

        if !opened, var restored = draft {
            let cutOff = restored.suggestion.isInFlight
            let recognize = cutOff && restored.photo != nil
            if recognize {
                restored.suggestion = .running
            } else if cutOff {
                restored.suggestion = .idle
            }
            return AddInitialState(state: restored, restored: true, recognize: recognize)
        }

        let photo = photoFromParams(params)
        var values = empty
        values.name = params.name?.jsTrimmed() ?? ""
        let containerId = params.containerId ?? ""
        return AddInitialState(
            state: AddDraftState(
                values: values,
                placeId: containerId.isEmpty ? DropZone.containerId : containerId,
                picked: nil,
                photo: photo,
                suggestion: photo == nil ? .idle : .running,
                showMore: false
            ),
            restored: false,
            recognize: photo != nil
        )
    }

    /// The short list under "Where it goes" (RN `whereEntries`): the container the sheet was
    /// opened for, the drop zone, then up to three recent places that still exist. A place
    /// picked from the full list that is not among them goes on top and stays there, the
    /// selected one first, so what is selected is always visible.
    public static func whereEntries(
        param: PlaceOption?,
        recentIds: [String],
        options: [String: PlaceOption],
        selectedId: String,
        picked: PlaceOption?,
        maxRecent: Int = maxRecentWhere
    ) -> [WhereEntry] {
        var entries: [WhereEntry] = []
        if let param { entries.append(.container(param, source: .param)) }
        entries.append(.dropZone)

        var recent = 0
        for id in recentIds {
            if recent >= maxRecent { break }
            if let param, EntityText.same(id, param.id) { continue }
            if EntityText.same(id, DropZone.containerId) { continue }
            guard let option = options[id] else { continue }
            entries.append(.container(option, source: .recent))
            recent += 1
        }

        let listed = entries.map(\.id)
        func isListed(_ id: String) -> Bool { listed.contains { EntityText.same($0, id) } }
        var extras: [PlaceOption] = []
        let selected: PlaceOption? = EntityText.same(selectedId, DropZone.containerId)
            ? nil
            : options[selectedId] ?? picked.flatMap { EntityText.same($0.id, selectedId) ? $0 : nil }
        if let selected, !isListed(selected.id) { extras.append(selected) }
        if let picked, !isListed(picked.id), !EntityText.same(picked.id, selected?.id) {
            extras.append(options[picked.id] ?? picked)
        }
        return extras.map { .container($0, source: .picked) } + entries
    }

    /// The place a save goes to (RN `resolvePlace`). A container the loaded list says no longer
    /// exists falls back to the drop zone, which the sheet then shows as selected; while the
    /// list loads (or failed) the id is kept.
    public static func resolvePlace(selectedId: String, options: [String: PlaceOption]?, picked: PlaceOption?) -> ResolvedPlace {
        if EntityText.same(selectedId, DropZone.containerId) { return ResolvedPlace(id: selectedId, option: nil) }
        let option = options?[selectedId] ?? picked.flatMap { EntityText.same($0.id, selectedId) ? $0 : nil }
        if let option { return ResolvedPlace(id: selectedId, option: option) }
        if options == nil { return ResolvedPlace(id: selectedId, option: nil) }
        return ResolvedPlace(id: DropZone.containerId, option: nil)
    }

    /// A container as written on screen: its name, or the code on its label (RN `containerTitle`).
    public static func containerTitle(_ option: PlaceOption) -> String {
        option.name ?? option.shortCode
    }

    /// The Save button's spoken label, naming where the item will go (RN `saveA11yLabel`).
    public static func saveAccessibilityLabel(_ place: ResolvedPlace) -> String {
        if place.isDropZone { return L10n.Add.saveA11yDropZone }
        guard let option = place.option else { return L10n.Add.save }
        let container = option.name ?? L10n.A11y.labelCode(spelled: spellCode(option.shortCode))
        return L10n.Add.saveA11y(container: container, space: option.spaceName)
    }

    /// The toast after a save: "Saved in Drawer by the oven (Kitchen)." (RN `savedMessage`).
    public static func savedMessage(_ place: ResolvedPlace) -> String {
        if place.isDropZone { return L10n.Add.savedInDropZone }
        guard let option = place.option else { return L10n.Add.saved }
        return L10n.Add.savedIn(container: containerTitle(option), space: option.spaceName)
    }

    /// The sheet's title (RN app/item/new.tsx:584-589): opened for a known container, "Add to
    /// <container>"; otherwise "Add an item". The place step has its own (`L10n.Add.placeTitle`).
    public static func title(param: PlaceOption?) -> String {
        param.map { L10n.Add.titleTo(container: containerTitle($0)) } ?? L10n.Add.title
    }
}
