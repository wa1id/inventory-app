import Foundation
import InventoryCore
import InventoryStrings

// RN: src/ui/spaces/spaceSetup.ts. The rules behind the Spaces tab and the space and container
// forms (07 §2.6).

/// What a space form edits (RN `SpaceValues`). Icon and colour are stored exactly as chosen.
public struct SpaceFormValues: Sendable, Hashable {
    public var name: String
    public var icon: String
    public var color: String

    public init(name: String, icon: String, color: String) {
        self.name = name
        self.icon = icon
        self.color = color
    }
}

/// What the container form edits (RN `ContainerValues`). The label code is not here: it never
/// changes. `visualType` keeps an unknown stored type as it is.
public struct ContainerFormValues: Sendable, Hashable {
    public var name: String
    public var visualType: ContainerVisualType
    public var spaceId: String

    public init(name: String, visualType: ContainerVisualType, spaceId: String) {
        self.name = name
        self.visualType = visualType
        self.spaceId = spaceId
    }
}

/// The space names already used, compared without case or surrounding white space
/// (RN `takenSpaceNames`' `Set`, whose keys compare as JS strings: code units, not canonically).
public struct TakenSpaceNames: Sendable, Hashable {
    private var units: Set<[UInt16]>

    init(keys: [String]) {
        units = Set(keys.map { Array($0.utf16) })
    }

    /// The folded names, each once.
    public var keys: [String] {
        units.map { String(decoding: $0, as: UTF16.self) }
    }

    func contains(_ key: String) -> Bool {
        units.contains(Array(key.utf16))
    }
}

/// Space and container form rules (RN `src/ui/spaces/spaceSetup.ts`).
public enum SpaceSetup {
    /// A container as people read it: its name, or else the code on its label
    /// (RN `containerLabel`). Unlike ``ContainerRules/labelOf(name:shortCode:)``, a blank name
    /// counts as a name (07 Q10; the repositories never store one).
    public static func containerLabel(name: String?, shortCode: String) -> String {
        name ?? shortCode
    }

    /// Containers sorted by label, ignoring case and accents, repository order kept on ties
    /// (RN `byContainerLabel` with JS's stable sort).
    public static func sortedByLabel<Row>(_ containers: [Row], name: (Row) -> String?, shortCode: (Row) -> String) -> [Row] {
        containers.entityStableSorted {
            EntityText.localeCompareBase(containerLabel(name: name($0), shortCode: shortCode($0)), containerLabel(name: name($1), shortCode: shortCode($1)))
        }
    }

    /// ``sortedByLabel(_:name:shortCode:)`` for a space's containers.
    public static func sortedByLabel(_ containers: [ContainerWithCounts]) -> [ContainerWithCounts] {
        sortedByLabel(containers, name: \.name, shortCode: \.shortCode)
    }

    /// The names already used by spaces, trimmed and lower-cased (RN `takenSpaceNames`).
    public static func takenSpaceNames(_ names: [String]) -> TakenSpaceNames {
        TakenSpaceNames(keys: names.map(nameKey))
    }

    /// ``takenSpaceNames(_:)`` for the spaces list.
    public static func takenSpaceNames(_ spaces: [SpaceWithCounts]) -> TakenSpaceNames {
        takenSpaceNames(spaces.map(\.name))
    }

    /// Whether a preset's name is already used (RN `isNameTaken`): shown as "Already added".
    public static func isNameTaken(_ name: String, taken: TakenSpaceNames) -> Bool {
        taken.contains(nameKey(name))
    }

    /// How many QR labels deleting a space unlinks: the larger of the impact's count and the
    /// containers' own tokens, since a household impact always reports 0 (RN `labelsInSpace`).
    public static func labelsInSpace(impactLabels: Int, containers: [ContainerWithCounts]) -> Int {
        labelsInSpace(impactLabels: impactLabels, qrTokens: containers.map(\.qrToken))
    }

    /// ``labelsInSpace(impactLabels:containers:)`` over the containers' label tokens.
    public static func labelsInSpace(impactLabels: Int, qrTokens: [String?]) -> Int {
        let linked = qrTokens.filter { !($0 ?? "").isEmpty }.count
        return max(impactLabels, linked)
    }

    /// The space delete confirm's body: everything that goes with it (RN `spaceDeleteBody`).
    public static func spaceDeleteBody(containerCount: Int, itemCount: Int, labels: Int) -> String {
        if containerCount == 0 && itemCount == 0 && labels == 0 { return L10n.SpaceForm.deleteEmpty }
        return L10n.SpaceForm.deleteBody(containers: containerCount, items: itemCount, labels: labels)
    }

    /// The container delete confirm's body, with the label it unlinks (RN `containerDeleteBody`).
    public static func containerDeleteBody(itemCount: Int, hasQrBinding: Bool) -> String {
        itemCount == 0
            ? L10n.ContainerForm.deleteEmpty(hasLabel: hasQrBinding)
            : L10n.ContainerForm.deleteBody(items: itemCount, hasLabel: hasQrBinding)
    }

    /// ``containerDeleteBody(itemCount:hasQrBinding:)`` for a deletion impact.
    public static func containerDeleteBody(_ impact: ContainerDeletionImpact) -> String {
        containerDeleteBody(itemCount: impact.itemCount, hasQrBinding: impact.hasQrBinding)
    }

    /// Whether a space form differs from where it started; surrounding white space in the name
    /// does not count, icon and colour compare exactly (RN `spaceValuesChanged`).
    public static func spaceValuesChanged(_ values: SpaceFormValues, initial: SpaceFormValues) -> Bool {
        EntityText.trimmedDiffer(values.name, initial.name)
            || !EntityText.same(values.icon, initial.icon)
            || !EntityText.same(values.color, initial.color)
    }

    /// Whether a container form differs from the stored container; an emptied name counts
    /// (RN `containerValuesChanged`).
    public static func containerValuesChanged(_ values: ContainerFormValues, initial: ContainerFormValues) -> Bool {
        EntityText.trimmedDiffer(values.name, initial.name)
            || !EntityText.same(values.visualType.rawValue, initial.visualType.rawValue)
            || !EntityText.same(values.spaceId, initial.spaceId)
    }

    /// RN `nameKey`: `name.trim().toLocaleLowerCase('en')`, which is the root lower-casing.
    static func nameKey(_ name: String) -> String {
        name.jsTrimmed().jsLowercased()
    }
}
