import Foundation
import InventoryCore
import InventoryServices
import Testing
@testable import InventoryAppModels

/// `src/ui/add/__tests__/addSheet.test.ts`.
private let entitiesDrawer = EntitiesFixtures.option("drawer", name: "Drawer by the oven", shortCode: "DRW-7K2M")
private let entitiesShelf = EntitiesFixtures.option("shelf", name: "Shelf A", spaceName: "Garage")

@Suite("addSheet params (addSheet.test.ts)")
struct EntitiesAddParamsTests {
    @Test("reads positive whole numbers only")
    func positiveInts() {
        #expect(AddSheet.toPositiveInt("1400") == 1400)
        for value in [nil, "", "0", "-3", "2.5", "wide"] as [String?] {
            #expect(AddSheet.toPositiveInt(value) == nil, "\(String(describing: value))")
        }
    }

    @Test("turns capture params into a photo")
    func fromParams() {
        #expect(AddSheet.photoFromParams(AddParams()) == nil)
        #expect(
            AddSheet.photoFromParams(
                AddParams(photoUri: "file:///p.webp", photoThumbUri: "file:///p-thumb.webp", photoWidth: "1400", photoHeight: "1050", photoBytes: "x"))
                == AddPhoto(uri: "file:///p.webp", thumbUri: "file:///p-thumb.webp", width: 1400, height: 1050, byteSize: nil)
        )
    }

    @Test("takes a stored camera photo, dropping an unknown size")
    func fromStored() {
        #expect(AddPhoto(StoredImage(uri: "a", thumbUri: "b", width: 10, height: 20, byteSize: nil))
            == AddPhoto(uri: "a", thumbUri: "b", width: 10, height: 20, byteSize: nil))
    }

    @Test("lists both files of a photo, so the thumbnail is never left behind")
    func photoFiles() {
        #expect(AddSheet.photoFiles(nil) == [])
        #expect(AddSheet.photoFiles(AddPhoto(uri: "a", thumbUri: "b")) == ["a", "b"])
        #expect(AddSheet.photoFiles(AddPhoto(uri: "a")) == ["a", nil])
    }

    @Test("the capture screen's params carry the stored photo")
    func captureParams() {
        let params = AddParams(containerId: "drop-zone", photo: StoredImage(uri: "a", thumbUri: "b", width: 10, height: 20, byteSize: 300))
        #expect(AddSheet.photoFromParams(params) == AddPhoto(uri: "a", thumbUri: "b", width: 10, height: 20, byteSize: 300))
        #expect(AddParams(containerId: nil, photo: StoredImage(uri: "a", thumbUri: "b", width: 1, height: 1, byteSize: nil)).photoBytes == nil)
    }
}

@Suite("addSheet content (addSheet.test.ts)")
struct EntitiesAddContentTests {
    @Test("counts typing, a changed quantity and a photo, not blanks")
    func content() {
        #expect(!AddSheet.formHasContent(.empty, photo: nil))
        #expect(!AddSheet.formHasContent(ItemFormValues(name: "   "), photo: nil))
        #expect(AddSheet.formHasContent(ItemFormValues(name: "AA batteries"), photo: nil))
        #expect(AddSheet.formHasContent(ItemFormValues(notes: "spare"), photo: nil))
        #expect(AddSheet.formHasContent(ItemFormValues(quantity: "0"), photo: nil))
        #expect(AddSheet.formHasContent(.empty, photo: AddPhoto(uri: "a")))
    }

    @Test("opens the details when any of them holds something")
    func details() {
        #expect(!AddSheet.hasDetails(.empty))
        #expect(!AddSheet.hasDetails(ItemFormValues(name: "Drill")))
        #expect(AddSheet.hasDetails(ItemFormValues(tags: "garage")))
    }
}

@Suite("initialAddState (addSheet.test.ts)")
struct EntitiesInitialAddStateTests {
    private let draft = AddDraftState(
        values: ItemFormValues(name: "Torch"), placeId: "shelf", picked: entitiesShelf, photo: nil, suggestion: .idle, showMore: false)

    @Test("starts empty in the drop zone from the tab bar")
    func plain() {
        #expect(
            AddSheet.initialState(params: AddParams(), draft: nil)
                == AddInitialState(
                    state: AddDraftState(values: .empty, placeId: DropZone.containerId, picked: nil, photo: nil, suggestion: .idle, showMore: false),
                    restored: false,
                    recognize: false
                )
        )
    }

    @Test("starts in the container it was opened for, with a name from search")
    func openedFor() {
        let state = AddSheet.initialState(params: AddParams(containerId: "drawer", name: "AA batteries"), draft: nil)
        #expect(state.state.placeId == "drawer")
        #expect(state.state.values.name == "AA batteries")
    }

    @Test("recognises a photo from the camera on arrival")
    func photoOnArrival() {
        let state = AddSheet.initialState(params: AddParams(containerId: "drawer", photoUri: "p"), draft: nil)
        #expect(state.state.photo?.uri == "p")
        #expect(state.state.suggestion == .running)
        #expect(state.recognize)
    }

    @Test("restores a draft only on a plain open")
    func restoresOnPlainOpen() {
        #expect(AddSheet.initialState(params: AddParams(), draft: draft) == AddInitialState(state: draft, restored: true, recognize: false))
        #expect(!AddSheet.initialState(params: AddParams(containerId: "drawer"), draft: draft).restored)
        #expect(AddSheet.initialState(params: AddParams(name: "Glue"), draft: draft).state.values.name == "Glue")
    }

    @Test("restarts recognition that was cut off, and drops it without a photo")
    func cutOff() {
        var refreshing = draft
        refreshing.photo = AddPhoto(uri: "p")
        refreshing.suggestion = .refreshing
        let running = AddSheet.initialState(params: AddParams(), draft: refreshing)
        #expect(running.state.suggestion == .running)
        #expect(running.recognize)

        var orphan = draft
        orphan.suggestion = .running
        let dropped = AddSheet.initialState(params: AddParams(), draft: orphan)
        #expect(dropped.state.suggestion == .idle)
        #expect(!dropped.recognize)
    }

    @Test("keeps an applied suggestion as it was")
    func keepsApplied() {
        var applied = draft
        applied.photo = AddPhoto(uri: "p")
        applied.suggestion = .applied(confidence: 0.8, forName: "Torch")
        let state = AddSheet.initialState(params: AddParams(), draft: applied)
        #expect(state.state.suggestion == .applied(confidence: 0.8, forName: "Torch"))
        #expect(!state.recognize)
    }
}

@Suite("whereEntries (addSheet.test.ts)")
struct EntitiesWhereEntriesTests {
    private let options: [String: PlaceOption] = Dictionary(
        uniqueKeysWithValues: [entitiesDrawer, entitiesShelf, EntitiesFixtures.option("bin"), EntitiesFixtures.option("bag"), EntitiesFixtures.option("crate")]
            .map { ($0.id, $0) })

    private func ids(_ entries: [WhereEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .dropZone: "drop"
            case .container(let option, let source): "\(source):\(option.id)"
            }
        }
    }

    @Test("offers the drop zone and up to three recent places that still exist")
    func recents() {
        #expect(
            ids(AddSheet.whereEntries(
                param: nil, recentIds: ["gone", "shelf", DropZone.containerId, "bin", "bag", "crate"], options: options,
                selectedId: DropZone.containerId, picked: nil))
                == ["drop", "recent:shelf", "recent:bin", "recent:bag"]
        )
    }

    @Test("puts the container it was opened for first, without repeating it")
    func paramFirst() {
        #expect(
            ids(AddSheet.whereEntries(param: entitiesDrawer, recentIds: ["drawer", "shelf"], options: options, selectedId: "drawer", picked: nil))
                == ["param:drawer", "drop", "recent:shelf"]
        )
    }

    @Test("shows a place picked from the full list on top")
    func pickedOnTop() {
        let fresh = EntitiesFixtures.option("new", name: "Just made")
        #expect(
            ids(AddSheet.whereEntries(param: nil, recentIds: ["shelf"], options: options, selectedId: "new", picked: fresh))
                == ["picked:new", "drop", "recent:shelf"]
        )
        #expect(
            ids(AddSheet.whereEntries(param: nil, recentIds: [], options: options, selectedId: "crate", picked: nil))
                == ["picked:crate", "drop"]
        )
    }

    @Test("keeps a picked place listed after choosing another one")
    func keepsPicked() {
        let fresh = EntitiesFixtures.option("new", name: "Just made")
        #expect(
            ids(AddSheet.whereEntries(param: nil, recentIds: ["shelf"], options: options, selectedId: DropZone.containerId, picked: fresh))
                == ["picked:new", "drop", "recent:shelf"]
        )
        #expect(
            ids(AddSheet.whereEntries(param: nil, recentIds: [], options: options, selectedId: "crate", picked: fresh))
                == ["picked:crate", "picked:new", "drop"]
        )
    }

    @Test("does not repeat a picked place that is already listed")
    func noRepeat() {
        #expect(
            ids(AddSheet.whereEntries(param: nil, recentIds: ["shelf"], options: options, selectedId: "shelf", picked: entitiesShelf))
                == ["drop", "recent:shelf"]
        )
    }

    @Test("an entry saves to its container, or to the drop zone")
    func entryIds() {
        #expect(WhereEntry.dropZone.id == DropZone.containerId)
        #expect(WhereEntry.container(entitiesShelf, source: .recent).id == "shelf")
    }
}

@Suite("resolvePlace (addSheet.test.ts)")
struct EntitiesResolvePlaceTests {
    private let options = ["drawer": entitiesDrawer]

    @Test("knows the drop zone and listed containers")
    func known() {
        #expect(AddSheet.resolvePlace(selectedId: DropZone.containerId, options: nil, picked: nil) == ResolvedPlace(id: DropZone.containerId, option: nil))
        #expect(AddSheet.resolvePlace(selectedId: "drawer", options: options, picked: nil) == ResolvedPlace(id: "drawer", option: entitiesDrawer))
    }

    @Test("keeps the id while the list loads, and a container just made")
    func loading() {
        #expect(AddSheet.resolvePlace(selectedId: "drawer", options: nil, picked: nil) == ResolvedPlace(id: "drawer", option: nil))
        let fresh = EntitiesFixtures.option("new")
        #expect(AddSheet.resolvePlace(selectedId: "new", options: options, picked: fresh) == ResolvedPlace(id: "new", option: fresh))
    }

    @Test("falls back to the drop zone for a container that is gone")
    func gone() {
        #expect(AddSheet.resolvePlace(selectedId: "gone", options: options, picked: nil) == ResolvedPlace(id: DropZone.containerId, option: nil))
    }
}

@Suite("addSheet labels (addSheet.test.ts)")
struct EntitiesAddLabelsTests {
    private let unnamed = EntitiesFixtures.option("u", name: .some(nil), shortCode: "BIN-4F2A", spaceName: "Loft")

    @Test("names a container by its name, or the code on its label")
    func titles() {
        #expect(AddSheet.containerTitle(entitiesDrawer) == "Drawer by the oven")
        #expect(AddSheet.containerTitle(unnamed) == "BIN-4F2A")
    }

    @Test("says where Save puts the item")
    func saveLabel() {
        #expect(AddSheet.saveAccessibilityLabel(ResolvedPlace(id: DropZone.containerId, option: nil)) == "Save to the drop zone")
        #expect(AddSheet.saveAccessibilityLabel(ResolvedPlace(id: "drawer", option: entitiesDrawer)) == "Save in Drawer by the oven, Kitchen")
        #expect(AddSheet.saveAccessibilityLabel(ResolvedPlace(id: "u", option: unnamed)) == "Save in label B I N, 4 F 2 A, Loft")
        #expect(AddSheet.saveAccessibilityLabel(ResolvedPlace(id: "drawer", option: nil)) == "Save")
    }

    @Test("reports where it was saved")
    func savedMessage() {
        #expect(AddSheet.savedMessage(ResolvedPlace(id: DropZone.containerId, option: nil)) == "Saved in the drop zone.")
        #expect(AddSheet.savedMessage(ResolvedPlace(id: "drawer", option: entitiesDrawer)) == "Saved in Drawer by the oven (Kitchen).")
        #expect(AddSheet.savedMessage(ResolvedPlace(id: "u", option: unnamed)) == "Saved in BIN-4F2A (Loft).")
        #expect(AddSheet.savedMessage(ResolvedPlace(id: "drawer", option: nil)) == "Saved.")
    }
}

/// The Add sheet helpers against `Fixtures/entities/entities-vectors.json` (`Number()` forms of
/// the photo params, JS white space in the content checks).
@Suite("addSheet parity (Fixtures/entities)")
struct EntitiesAddSheetParityTests {
    struct PositiveCase: Decodable {
        let value: String
        let expected: Int?
    }

    struct Params: Decodable {
        let photoUri: String?
        let photoThumbUri: String?
        let photoWidth: String?
        let photoHeight: String?
        let photoBytes: String?
    }

    struct Photo: Decodable {
        let uri: String
        let thumbUri: String?
        let width: Int?
        let height: Int?
        let byteSize: Int?
    }

    struct ParamsCase: Decodable {
        let params: Params
        let photo: Photo?
    }

    struct Values: Decodable {
        let name, category, tags, quantity, notes: String
    }

    struct ContentCase: Decodable {
        let values: Values
        let hasDetails: Bool
        let hasContent: Bool
    }

    struct Fixture: Decodable {
        let toPositiveInt: [PositiveCase]
        let photoFromParams: [ParamsCase]
        let content: [ContentCase]
    }

    @Test("toPositiveInt, photoFromParams, hasDetails and formHasContent match JS")
    func matches() throws {
        let url = try #require(Bundle.module.url(forResource: "entities-vectors", withExtension: "json", subdirectory: "Fixtures/entities"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for vector in fixture.toPositiveInt {
            #expect(AddSheet.toPositiveInt(vector.value) == vector.expected, "\(vector.value)")
        }
        for vector in fixture.photoFromParams {
            let params = AddParams(
                photoUri: vector.params.photoUri, photoThumbUri: vector.params.photoThumbUri, photoWidth: vector.params.photoWidth,
                photoHeight: vector.params.photoHeight, photoBytes: vector.params.photoBytes)
            let expected = vector.photo.map { AddPhoto(uri: $0.uri, thumbUri: $0.thumbUri, width: $0.width, height: $0.height, byteSize: $0.byteSize) }
            #expect(AddSheet.photoFromParams(params) == expected)
        }
        for vector in fixture.content {
            let values = ItemFormValues(
                name: vector.values.name, category: vector.values.category, tags: vector.values.tags, quantity: vector.values.quantity,
                notes: vector.values.notes)
            #expect(AddSheet.hasDetails(values) == vector.hasDetails, "\(vector.values)")
            #expect(AddSheet.formHasContent(values, photo: nil) == vector.hasContent, "\(vector.values)")
        }
    }
}
