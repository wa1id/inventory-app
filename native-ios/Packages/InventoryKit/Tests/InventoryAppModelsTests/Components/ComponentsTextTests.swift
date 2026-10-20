import Foundation
import InventoryCore
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// The field copy of TextField.tsx, CodeInput.tsx and QuantityStepper.tsx (07 §4.7, §4.10).
@Suite("Field copy (TextField.tsx, CodeInput.tsx, QuantityStepper.tsx)")
struct ComponentsFieldTextTests {
    @Test("the spoken label adds required and the error")
    func spokenLabel() {
        #expect(TextFieldCopy.spokenLabel(label: "Name", required: false, error: nil) == "Name")
        #expect(TextFieldCopy.spokenLabel(label: "What is it?", accessibilityLabel: "Name", required: true, error: nil) == "Name, \(L10n.Forms.required)")
        #expect(
            TextFieldCopy.spokenLabel(label: "Name", required: true, error: "Give it a name.")
                == "Name, \(L10n.Forms.required), \(L10n.Forms.errorA11y(error: "Give it a name."))"
        )
        #expect(TextFieldCopy.spokenLabel(label: "Name", required: false, error: "") == "Name")
    }

    @Test("the code field shows groups of five and stores the normalised code")
    func codeDisplay() {
        #expect(CodeFieldText.normalise(" mmwky-m2h78 ") == "MMWKYM2H78")
        #expect(CodeFieldText.normalise("il0o") == "1100")
        #expect(CodeFieldText.display("MMWKYM2H78A") == "MMWKY-M2H78-A")
        #expect(CodeFieldText.display("") == "")
        // Display then normalise round-trips, so editing the shown text never changes the code.
        let code = "89144GJ289ABCDEFGHJKMNPQRS"
        #expect(CodeFieldText.normalise(CodeFieldText.display(code)) == code)
    }

    @Test("the counter shows once there is something to count, and is read even when empty")
    func codeCounter() {
        #expect(CodeFieldText.visibleCounter("") == nil)
        #expect(CodeFieldText.visibleCounter("ABC") == L10n.Forms.codeCounter(count: 3, total: 26))
        #expect(CodeFieldText.counter("") == L10n.Forms.codeCounter(count: 0, total: 26))
        #expect(CodeFieldText.counter("ABCDE", length: 10) == L10n.Forms.codeCounter(count: 5, total: 10))
    }

    @Test("only the Return key submits; a pasted line break is just normalised")
    func codeSubmit() {
        // Return at the end or in the middle of what was shown submits.
        #expect(CodeFieldText.isReturnKey(shown: "MMWKY-M2H78", typed: "MMWKY-M2H78\n"))
        #expect(CodeFieldText.isReturnKey(shown: "MMWKY-M2H78", typed: "MMWKY\n-M2H78"))
        #expect(CodeFieldText.isReturnKey(shown: "", typed: "\n"))
        // Typing and pasting do not, even when the paste brings line breaks along.
        #expect(!CodeFieldText.isReturnKey(shown: "MMWKY", typed: "MMWKYM"))
        #expect(!CodeFieldText.isReturnKey(shown: "MMWKY", typed: "MMWKYM2H78\n"))
        #expect(!CodeFieldText.isReturnKey(shown: "", typed: "MMWKY\nM2H78"))
        #expect(!CodeFieldText.isReturnKey(shown: "", typed: "MMWKY\nM2H78\n"))
    }

    @Test("the stepper names the item or speaks plainly")
    func stepperCopy() {
        #expect(QuantityStepperCopy.increaseLabel(itemName: "Screws") == L10n.Quantity.increase(name: "Screws"))
        #expect(QuantityStepperCopy.decreaseLabel(itemName: nil) == L10n.Quantity.decreasePlain)
        #expect(QuantityStepperCopy.fieldLabel(itemName: nil) == L10n.Quantity.fieldPlain)
        #expect(QuantityStepperCopy.valueText(0) == L10n.Rows.noneLeft)
        #expect(QuantityStepperCopy.valueText(12) == "12")
        #expect(QuantityStepperCopy.identifier("input", suffix: nil) == "quantity-input")
        #expect(QuantityStepperCopy.identifier("increase", suffix: "i1") == "quantity-increase-i1")
    }
}

/// The place rows, the location line and the where card (PlaceRows.tsx, LocationLine.tsx,
/// WhereCard.tsx; 06 §5.7, 07 §4.3-4.5).
@Suite("Place row text (PlaceRows.tsx, LocationLine.tsx, WhereCard.tsx)")
struct ComponentsPlaceRowTextTests {
    static func place(containerId: String = "c1", name: String? = "Tool chest") -> RowPlace {
        RowPlace(containerId: containerId, containerName: name, containerShortCode: "CAB-J92R", spaceId: "s1", spaceName: "Garage", spaceColor: "#5B8DEF")
    }

    @Test("unknown types read as Container; unnamed containers by their type")
    func typeNames() {
        #expect(PlaceRowText.typeName(.drawer) == "Drawer")
        #expect(PlaceRowText.typeName("Box") == "Container")
        #expect(PlaceRowText.containerLabel(name: nil, visualType: .bag) == "Unnamed bag")
        #expect(PlaceRowText.containerLabel(name: nil, visualType: "spaceship") == "Unnamed container")
        #expect(PlaceRowText.containerLabel(name: "Tool chest", visualType: .cabinet) == "Tool chest")
    }

    @Test("a container in its space says what it holds and whether it has a label")
    func containerMeta() {
        #expect(PlaceRowText.containerMeta(itemCount: 0, hasLabel: false) == L10n.Entities.contents(count: 0))
        #expect(PlaceRowText.containerMeta(itemCount: 3, hasLabel: true) == "3 items · QR label")
    }

    @Test("container rows spell the code and say the label only when there is one")
    func containerLabel() {
        let row = ContainerRowData(id: "c1", name: "Tool chest", shortCode: "CAB-J92R", visualType: .cabinet, itemCount: 3)
        #expect(
            PlaceRowText.containerAccessibilityLabel(row)
                == L10n.Rows.containerA11y(label: "Tool chest", type: "Cabinet", spelled: "C A B, J 9 2 R", items: "3 items", hasLabel: false)
        )
        var labelled = row
        labelled.qrToken = "abc"
        #expect(PlaceRowText.containerAccessibilityLabel(labelled) == L10n.Rows.containerA11y(label: "Tool chest", type: "Cabinet", spelled: "C A B, J 9 2 R", items: "3 items", hasLabel: true))
        // JS truthiness: an empty token is no label.
        labelled.qrToken = ""
        #expect(!labelled.hasLabel)
        #expect(PlaceRowText.containerAccessibilityLabel(labelled) == L10n.Rows.containerA11y(label: "Tool chest", type: "Cabinet", spelled: "C A B, J 9 2 R", items: "3 items", hasLabel: false))
    }

    @Test("space rows speak their counts")
    func spaceLabel() {
        #expect(PlaceRowText.spaceAccessibilityLabel(name: "Garage", containers: 2, items: 5) == L10n.Rows.spaceA11y(name: "Garage", counts: "2 containers and 5 items"))
        #expect(PlaceRowText.spaceCounts(containers: 0, items: 9) == "No containers yet")
    }

    @Test("the location line names the container, or its code where no tape is drawn")
    func locationLabel() {
        #expect(PlaceRowText.locationContainerLabel(Self.place(), showsTape: true) == "Tool chest")
        #expect(PlaceRowText.locationContainerLabel(Self.place(name: nil), showsTape: true) == nil)
        #expect(PlaceRowText.locationContainerLabel(Self.place(name: nil), showsTape: false) == "CAB-J92R")
        #expect(PlaceRowText.locationContainerLabel(Self.place(name: ""), showsTape: false) == "")
        #expect(PlaceRowText.isDropZone(Self.place(containerId: DropZone.containerId)))
        #expect(!PlaceRowText.isDropZone(Self.place()))
    }

    @Test("a hit joins with the lists, or shows as given")
    func placeRowJoin() {
        let space = SpaceWithCounts(space: Space(id: "s1", name: "Garage", icon: "🚗", color: "#5B8DEF", createdAt: 0, updatedAt: 0), containerCount: 1, itemCount: 2)
        let container = ContainerWithSpace(
            container: Container(id: "c1", spaceId: "s1", name: nil, visualType: .bin, shortCode: "BIN-2345", createdAt: 0, updatedAt: 0),
            spaceName: "Garage",
            itemCount: 9
        )
        let spaceHit = LocationSearchResult(kind: .space, id: "s1", title: "Garage", subtitle: "1 container", spaceId: "s1", itemCount: 2)
        let containerHit = LocationSearchResult(kind: .container, id: "c1", title: "BIN-2345", subtitle: "Garage", spaceId: "s1", itemCount: 4)
        let lonely = LocationSearchResult(kind: .container, id: "c9", title: "Shelf", subtitle: "In Loft", spaceId: "s9", itemCount: 0)

        #expect(PlaceRowContent.resolve(spaceHit, spaces: ["s1": space], containers: [:]) == .space(space))
        guard case .container(let row) = PlaceRowContent.resolve(containerHit, spaces: ["s1": space], containers: ["c1": container]) else {
            Issue.record("expected a container row")
            return
        }
        // The hit's own count, the space's colour, and no label token in search.
        #expect(row.itemCount == 4)
        #expect(row.spaceColor == "#5B8DEF")
        #expect(row.qrToken == nil)
        #expect(PlaceRowContent.resolve(spaceHit, spaces: [:], containers: [:]) == .hit(spaceHit))
        #expect(PlaceRowContent.resolve(lonely, spaces: ["s1": space], containers: ["c1": container]) == .hit(lonely))
        #expect(PlaceRowText.hitAccessibilityLabel(lonely) == "Shelf. In Loft")
    }

    @Test("the where card files from the drop zone and moves from anywhere else")
    func whereCard() {
        let filed = WhereCardCopy(place: Self.place(), name: "Drill")
        #expect(filed.actionTitle == L10n.Item.move)
        #expect(filed.actionAccessibilityLabel == L10n.Item.moveA11y(name: "Drill"))
        #expect(filed.actionIdentifier == "item-move")
        let waiting = WhereCardCopy(place: Self.place(containerId: DropZone.containerId), name: "")
        #expect(waiting.isDropZone)
        #expect(waiting.actionTitle == L10n.Item.fileIt)
        #expect(waiting.actionAccessibilityLabel == L10n.Item.fileItA11yUnnamed)
        #expect(waiting.actionIdentifier == "item-file")
    }

    @Test("identifiers keep the RN testIDs")
    func identifiers() {
        #expect(PlaceRowText.spaceIdentifier("s") == "space-row-s")
        #expect(PlaceRowText.containerIdentifier("c") == "container-row-c")
        #expect(PlaceRowText.placeIdentifier("h") == "place-row-h")
    }
}

/// Banner.tsx, ErrorState.tsx and SettingsRow.tsx wording (06 §15.1, §17).
@Suite("Feedback text (Banner.tsx, ErrorState.tsx, SettingsRow.tsx)")
struct ComponentsFeedbackTextTests {
    @Test("a banner announces its title and message, or the message alone")
    func bannerAnnouncement() {
        #expect(FeedbackText.bannerAnnouncement(title: "Saved", message: "Check it.") == "Saved. Check it.")
        #expect(FeedbackText.bannerAnnouncement(title: nil, message: "Check it.") == "Check it.")
        #expect(FeedbackText.bannerAnnouncement(title: "", message: "Check it.") == "Check it.")
        #expect(!BannerLiveness.off.announces)
        #expect(BannerLiveness.assertive.announces)
    }

    @Test("an error state uses the described words unless the screen gives its own")
    func errorState() {
        let gone = FeedbackText.errorState(cause: nil, subject: .item)
        #expect(gone.title == describeError(nil, subject: .item).title)
        let custom = FeedbackText.errorState(cause: nil, title: "T", body: "B")
        #expect(custom.title == "T")
        #expect(custom.body == "B")
    }

    @Test("a settings row speaks its value with its label")
    func settingsLabel() {
        #expect(FeedbackText.settingsAccessibilityLabel(label: "Backup", value: "On") == "Backup, On")
        #expect(FeedbackText.settingsAccessibilityLabel(label: "Privacy", value: nil) == "Privacy")
    }
}
