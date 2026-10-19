// The strings.ts functions whose wording branches on their arguments. Each branch
// has its own catalog entry (the `…Keys` enums in the generated L10n.swift); the
// code here only picks one, exactly as the TS does. Signatures keep the TS
// parameter names. The parity tests check every function against strings.ts.

extension L10n.Entities {
    /// "Unnamed box" … "Unnamed container": the type name, lower-cased, after "Unnamed".
    ///
    /// Callers pass `TypeNames[visualType] ?? TypeNames.other`; each known name has
    /// its own entry. Any other name is lower-cased as JS does.
    // RN: src/i18n/strings.ts:76
    public static func unnamedContainer(typeName: String) -> String {
        if let type = TypeNames.allKeys.first(where: { L10nRuntime.same(TypeNames[$0] ?? "", typeName) }),
           let text = UnnamedContainerKeys.perType(type) {
            return text
        }
        return UnnamedContainerKeys.base(typeName: JSText.lowercased(typeName))
    }

    /// What a container holds: "Empty" for 0, otherwise "1 item", "3 items".
    // RN: src/i18n/strings.ts:105
    public static func contents(count: Int) -> String {
        count == 0 ? ContentsKeys.empty : items(count: count)
    }

    /// "No containers yet" (items ignored); "1 container, empty" or
    /// "2 containers, all empty"; otherwise "2 containers and 5 items".
    // RN: src/i18n/strings.ts:107
    public static func spaceCounts(containers: Int, items: Int) -> String {
        if containers == 0 { return SpaceCountsKeys.none }
        if items == 0 { return SpaceCountsKeys.empty(containers: containers) }
        return SpaceCountsKeys.some(containers: containers, items: items)
    }
}

extension L10n.Rows {
    /// The relative time with its first letter upper-cased ("Just now", "Yesterday"),
    /// for lists of new additions where "Added" goes without saying.
    // RN: src/i18n/strings.ts:124
    public static func addedShort(ago: String) -> String {
        JSText.capitalizeFirst(ago)
    }

    /// "<label>, <type>, label <spelled>. <items>." with ". Has a QR label" before the
    /// final full stop when `hasLabel`.
    // RN: src/i18n/strings.ts:128
    public static func containerA11y(label: String, type: String, spelled: String, items: String, hasLabel: Bool) -> String {
        hasLabel
            ? ContainerA11yKeys.withLabel(label: label, type: type, spelled: spelled, items: items)
            : ContainerA11yKeys.base(label: label, type: type, spelled: spelled, items: items)
    }
}

extension L10n.Quantity {
    /// "The quantity of “<name>” was not saved." then a hint that depends on `offline`.
    // RN: src/i18n/strings.ts:166
    public static func notSavedNamed(name: String, offline: Bool) -> String {
        offline ? NotSavedNamedKeys.offline(name: name) : NotSavedNamedKeys.other(name: name)
    }
}

extension L10n.Forms {
    /// "More details, expanded" or "More details, collapsed".
    // RN: src/i18n/strings.ts:201
    public static func moreDetailsA11y(expanded: Bool) -> String {
        expanded ? MoreDetailsA11yKeys.expanded : MoreDetailsA11yKeys.collapsed
    }
}

extension L10n.Camera {
    /// "Torch, on" or "Torch, off".
    // RN: src/i18n/strings.ts:312
    public static func torchState(on: Bool) -> String {
        on ? TorchStateKeys.on : TorchStateKeys.off
    }
}

extension L10n.Search {
    /// "Nothing found" when both are 0; otherwise the non-zero counts joined:
    /// "3 items and 1 place found", "1 item found", "2 places found".
    // RN: src/i18n/strings.ts:371
    public static func summary(items: Int, places: Int) -> String {
        let (total, overflow) = items.addingReportingOverflow(places)
        if !overflow && total == 0 { return SummaryKeys.none }
        if items != 0 && places != 0 { return SummaryKeys.both(items: items, places: places) }
        return items != 0 ? SummaryKeys.items(items: items) : SummaryKeys.places(places: places)
    }
}

extension L10n.SpaceForm {
    /// "This also deletes <N containers> and <N items>", then ", and unlinks <N QR labels>"
    /// when `labels` is not 0, then ". This cannot be undone." Both counts always show.
    // RN: src/i18n/strings.ts:442
    public static func deleteBody(containers: Int, items: Int, labels: Int) -> String {
        labels != 0
            ? DeleteBodyKeys.withLabels(containers: containers, items: items, labels: labels)
            : DeleteBodyKeys.noLabels(containers: containers, items: items)
    }

    /// "<name> was not deleted." then a hint that depends on `offline`.
    // RN: src/i18n/strings.ts:451
    public static func deleteFailed(name: String, offline: Bool) -> String {
        offline ? DeleteFailedKeys.offline(name: name) : DeleteFailedKeys.other(name: name)
    }

    /// "<name> was not added." then a hint that depends on `offline`.
    // RN: src/i18n/strings.ts:459
    public static func notCreated(name: String, offline: Bool) -> String {
        offline ? NotCreatedKeys.offline(name: name) : NotCreatedKeys.other(name: name)
    }

    /// "Changes to <name> were not saved." then a hint that depends on `offline`.
    // RN: src/i18n/strings.ts:463
    public static func notSaved(name: String, offline: Bool) -> String {
        offline ? NotSavedKeys.offline(name: name) : NotSavedKeys.other(name: name)
    }
}

extension L10n.ContainerForm {
    /// "This also deletes <N items>", then " and unlinks its QR label" when `hasLabel`,
    /// then ". This cannot be undone."
    // RN: src/i18n/strings.ts:489
    public static func deleteBody(items: Int, hasLabel: Bool) -> String {
        hasLabel ? DeleteBodyKeys.withLabel(items: items) : DeleteBodyKeys.base(items: items)
    }

    /// "This container is empty." plus " Its QR label will be unlinked." when `hasLabel`.
    // RN: src/i18n/strings.ts:491
    public static func deleteEmpty(hasLabel: Bool) -> String {
        hasLabel ? DeleteEmptyKeys.withLabel : DeleteEmptyKeys.base
    }

    /// "<label> was not deleted." then a hint that depends on `offline`.
    // RN: src/i18n/strings.ts:496
    public static func deleteFailed(label: String, offline: Bool) -> String {
        offline ? DeleteFailedKeys.offline(label: label) : DeleteFailedKeys.other(label: label)
    }

    /// "The container was not added." then a hint that depends on `offline`.
    // RN: src/i18n/strings.ts:504
    public static func notCreated(offline: Bool) -> String {
        offline ? NotCreatedKeys.offline : NotCreatedKeys.other
    }

    /// "Changes to <label> were not saved." then a hint that depends on `offline`.
    // RN: src/i18n/strings.ts:508
    public static func notSaved(label: String, offline: Bool) -> String {
        offline ? NotSavedKeys.offline(label: label) : NotSavedKeys.other(label: label)
    }
}

extension L10n.Container.Empty {
    /// "This box is empty" … "This container is empty": the type name, lower-cased.
    ///
    /// Callers pass a type name; each known name has its own entry. Any other name
    /// is lower-cased as JS does.
    // RN: src/i18n/strings.ts:527
    public static func title(type: String) -> String {
        let names = L10n.Entities.TypeNames.self
        if let visualType = names.allKeys.first(where: { L10nRuntime.same(names[$0] ?? "", type) }),
           let text = TitleKeys.perType(visualType) {
            return text
        }
        return TitleKeys.base(type: JSText.lowercased(type))
    }
}

extension L10n.Qr {
    /// "The label was not made." then a hint that depends on `offline`.
    // RN: src/i18n/strings.ts:559
    public static func makeFailed(offline: Bool) -> String {
        offline ? MakeFailedKeys.offline : MakeFailedKeys.other
    }

    /// "The label was not replaced, so the old sticker still works." then a hint.
    // RN: src/i18n/strings.ts:563
    public static func replaceFailed(offline: Bool) -> String {
        offline ? ReplaceFailedKeys.offline : ReplaceFailedKeys.other
    }

    /// "The label was not removed, so the sticker still opens this container." then a hint.
    // RN: src/i18n/strings.ts:567
    public static func removeFailed(offline: Bool) -> String {
        offline ? RemoveFailedKeys.offline : RemoveFailedKeys.other
    }
}

extension L10n.Item {
    /// "The item was not deleted." then a hint that depends on `offline`.
    // RN: src/i18n/strings.ts:636
    public static func deleteFailed(offline: Bool) -> String {
        offline ? DeleteFailedKeys.offline : DeleteFailedKeys.other
    }
}

extension L10n.Add {
    /// "It was not removed." then a hint that depends on `offline`.
    // RN: src/i18n/strings.ts:718
    public static func undoFailed(offline: Bool) -> String {
        offline ? UndoFailedKeys.offline : UndoFailedKeys.other
    }
}

extension L10n.Capture {
    /// "Flash, on" or "Flash, off".
    // RN: src/i18n/strings.ts:766
    public static func flash(on: Bool) -> String {
        on ? FlashKeys.on : FlashKeys.off
    }

    /// "Done" for no photos, otherwise "Done, 3 photos taken".
    // RN: src/i18n/strings.ts:771
    public static func doneA11y(count: Int) -> String {
        count == 0 ? done : DoneA11yKeys.base(count: count)
    }
}

extension L10n.Review {
    /// "The item was not deleted." then a hint that depends on `offline`.
    // RN: src/i18n/strings.ts:804
    public static func deleteFailed(offline: Bool) -> String {
        offline ? DeleteFailedKeys.offline : DeleteFailedKeys.other
    }
}

extension L10n.DeepLink {
    /// "The label was not linked." then a hint that depends on `offline`.
    // RN: src/i18n/strings.ts:845
    public static func linkFailed(offline: Bool) -> String {
        offline ? LinkFailedKeys.offline : LinkFailedKeys.other
    }
}
