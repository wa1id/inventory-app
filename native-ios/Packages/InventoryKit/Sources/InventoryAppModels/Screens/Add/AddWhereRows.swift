import InventoryCore
import InventoryStrings

// RN: src/ui/add/WhereList.tsx. How each "Where it goes" row speaks, what it is called in the
// UI tests, and the location it draws (06 §10.5, 07 §4.2).

extension WhereEntry {
    /// The row's test identifier (RN `entryTestID`): `item-where-drop-zone`, a recent place
    /// `item-where-recent-<id>`, the container the sheet was opened for or one picked from the
    /// full list `item-where-<id>`.
    public var whereIdentifier: String {
        switch self {
        case .dropZone: "item-where-drop-zone"
        case .container(let option, .recent): "item-where-recent-\(option.id)"
        case .container(let option, _): "item-where-\(option.id)"
        }
    }

    /// What VoiceOver reads for the row: "Drop zone, Sort it later", or the picker's
    /// "<name or Unnamed box>, <space>, label <spelled code>" (RN `WhereList.tsx:79-86`).
    public var whereAccessibilityLabel: String {
        switch self {
        case .dropZone:
            "\(L10n.Add.dropZone), \(L10n.Add.sortLater)"
        case .container(let option, _):
            L10n.Picker.optionA11y(label: PlacePickerRules.optionLabel(option), space: option.spaceName, spelled: spellCode(option.shortCode))
        }
    }

    /// The location a container row draws ("● Space › Container [CODE]"); nil for the drop
    /// zone, which draws its tray and "Sort it later" instead.
    public var wherePlace: RowPlace? {
        switch self {
        case .dropZone:
            nil
        case .container(let option, _):
            RowPlace(
                containerId: option.id,
                containerName: option.name,
                containerShortCode: option.shortCode,
                spaceId: option.spaceId,
                spaceName: option.spaceName,
                spaceColor: option.spaceColor
            )
        }
    }

    /// The container type the row's tile shows; the drop zone's tile is the tray.
    public var whereVisualType: ContainerVisualType? {
        switch self {
        case .dropZone: nil
        case .container(let option, _): option.visualType
        }
    }
}

extension AddSheetModel {
    /// Whether `entry` is where a save goes now: its row shows the checkmark and reads as
    /// selected (RN `WhereList` `selected`).
    public func isChosen(_ entry: WhereEntry) -> Bool {
        EntityText.same(entry.id, place.id)
    }
}
