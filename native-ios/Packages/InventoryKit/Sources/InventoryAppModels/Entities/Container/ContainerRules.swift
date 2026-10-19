import Foundation
import InventoryCore
import InventoryStrings

// RN: src/ui/container/containerRules.ts. The rules behind the container screen, its QR label
// and sticker linking (07 §2.5).

/// What scanning a sticker for a container leads to (RN `StickerPlan`).
public enum StickerPlan: Sendable, Hashable {
    /// Not one of our codes.
    case invalid
    /// It already opens this container: nothing to write.
    case already
    /// Bind `token` to the container, asking first when `confirm` is set (destructive style).
    case link(token: String, confirm: ConfirmOptions?)
}

/// The label the QR screen has just written: nil token after a remove (RN `WrittenLabel`).
public struct WrittenLabel: Sendable, Hashable {
    public var token: String?
    /// The read the write set off has started.
    public var reloading: Bool

    public init(token: String?, reloading: Bool) {
        self.token = token
        self.reloading = reloading
    }
}

/// A label change on the QR screen (RN `LabelAction`).
public enum QrLabelAction: Sendable, Hashable {
    case make
    case replace
    case remove
}

/// Container screen, QR label and sticker rules (RN `src/ui/container/containerRules.ts`).
public enum ContainerRules {
    /// How recently an item must have been added to count as just arrived (RN `FRESH_ARRIVAL_MS`).
    public static let freshArrivalMs: Int64 = 10_000

    /// What a sentence calls a container: its name, or else the code on its label. A name of
    /// only white space reads as unnamed (RN `labelOf`).
    public static func labelOf(name: String?, shortCode: String) -> String {
        if let name, EntityText.hasText(name) { return name }
        return shortCode
    }

    /// ``labelOf(name:shortCode:)`` for a container.
    public static func labelOf(_ container: Container) -> String {
        labelOf(name: container.name, shortCode: container.shortCode)
    }

    /// "Box", "Drawer"…; an unknown stored type reads as "Container" (RN `typeNameOf`).
    public static func typeNameOf(_ visualType: ContainerVisualType) -> String {
        L10n.Entities.TypeNames[visualType.rawValue] ?? L10n.Entities.TypeNames.other
    }

    /// The container's title: its name, or "Unnamed box" (RN `titleOf`).
    public static func titleOf(name: String?, visualType: ContainerVisualType) -> String {
        if let name, EntityText.hasText(name) { return name }
        return L10n.Entities.unnamedContainer(typeName: typeNameOf(visualType))
    }

    /// ``titleOf(name:visualType:)`` for a container.
    public static func titleOf(_ container: Container) -> String {
        titleOf(name: container.name, visualType: container.visualType)
    }

    /// What is in a box, in the order people look for it (RN `sortContents`): by trimmed name,
    /// ignoring case and accents, ties by `createdAt`; items still waiting for a name last, in
    /// the order they were added. Returns a sorted copy.
    public static func sortContents<Row>(_ items: [Row], name: (Row) -> String, createdAt: (Row) -> Int64) -> [Row] {
        items.entityStableSorted { a, b in
            let nameA = name(a).jsTrimmed()
            let nameB = name(b).jsTrimmed()
            if !nameA.isEmpty && !nameB.isEmpty {
                let order = EntityText.localeCompareBase(nameA, nameB)
                return order == .orderedSame ? compare(createdAt(a), createdAt(b)) : order
            }
            if !nameA.isEmpty { return .orderedAscending }
            if !nameB.isEmpty { return .orderedDescending }
            return compare(createdAt(a), createdAt(b))
        }
    }

    /// ``sortContents(_:name:createdAt:)`` for a container's items.
    public static func sortContents(_ items: [ItemWithContext]) -> [ItemWithContext] {
        sortContents(items, name: \.name, createdAt: \.createdAt)
    }

    /// Whether a row has just arrived and is picked out for a moment: within ten seconds either
    /// side of `now`, since a paired phone's clock and the home server's differ (RN `isFreshArrival`).
    public static func isFreshArrival(createdAt: Int64, now: Int64) -> Bool {
        let (difference, overflow) = now.subtractingReportingOverflow(createdAt)
        guard !overflow else { return false }
        return difference.magnitude < UInt64(freshArrivalMs)
    }

    /// Decides what a scanned sticker does to `target` (RN `planSticker`).
    ///
    /// A new sticker links at once unless the container already has a label, whose sticker
    /// would stop working; one that opens another container moves only after saying which one
    /// loses it.
    public static func planSticker(
        _ outcome: ScanOutcome,
        targetId: String,
        targetName: String?,
        targetShortCode: String,
        targetQrToken: String?
    ) -> StickerPlan {
        let token: String
        switch outcome {
        case .invalid: return .invalid
        case .bound(_, let bound), .unknown(let bound): token = bound
        }
        let label = labelOf(name: targetName, shortCode: targetShortCode)
        let replacing = targetQrToken.map { !EntityText.same($0, token) } ?? false

        if case .bound(let container, _) = outcome {
            if EntityText.same(container.id, targetId) { return .already }
            let moveBody = L10n.Link.moveBody(from: labelOf(container), to: label)
            return .link(
                token: token,
                confirm: ConfirmOptions(
                    title: L10n.Link.moveTitle(label: label),
                    // Moving it here also retires this container's own sticker, if it has one.
                    body: replacing ? "\(moveBody) \(L10n.Link.replaceBody(label: label))" : moveBody,
                    confirmLabel: L10n.Link.move
                )
            )
        }

        return .link(
            token: token,
            confirm: replacing
                ? ConfirmOptions(
                    title: L10n.Link.replaceTitle(label: label),
                    body: L10n.Link.replaceBody(label: label),
                    confirmLabel: L10n.Link.replace
                )
                : nil
        )
    }

    /// ``planSticker(_:targetId:targetName:targetShortCode:targetQrToken:)`` for a container read
    /// with its counts (which carries its label token).
    public static func planSticker(_ outcome: ScanOutcome, target: ContainerWithCounts) -> StickerPlan {
        planSticker(
            outcome,
            targetId: target.id,
            targetName: target.name,
            targetShortCode: target.shortCode,
            targetQrToken: target.qrToken
        )
    }

    /// What the QR screen keeps showing after its own make, replace or remove, given the state
    /// of the label's read (RN `settleWrittenLabel`).
    ///
    /// The written label holds until a read that started after the write has come back; if
    /// that read fails it holds on until a later read succeeds, so a retired sticker is never
    /// offered for printing. Returns `written` itself when nothing changes.
    public static func settleWrittenLabel(_ written: WrittenLabel?, loading: Bool, failed: Bool) -> WrittenLabel? {
        guard let written else { return nil }
        if !written.reloading {
            return loading ? WrittenLabel(token: written.token, reloading: true) : written
        }
        if loading { return written }
        return failed ? WrittenLabel(token: written.token, reloading: false) : nil
    }

    /// The error toast for a label change that did not happen, saying what still holds
    /// (RN `labelFailureMessage`).
    public static func labelFailureMessage(_ action: QrLabelAction, cause: any Error) -> String {
        let kind = describeError(cause, context: .label, subject: .container).kind
        if kind == .gone { return L10n.Qr.containerGone }
        let offline = kind == .offline
        switch action {
        case .make: return L10n.Qr.makeFailed(offline: offline)
        case .replace: return L10n.Qr.replaceFailed(offline: offline)
        case .remove: return L10n.Qr.removeFailed(offline: offline)
        }
    }

    /// What the share sheet carries besides the picture: "<label> (<code>)", plus the link on a
    /// second line when no picture goes (RN `shareText`).
    public static func shareText(name: String?, shortCode: String, payload: String, withPayload: Bool) -> String {
        let message = L10n.Qr.shareMessage(label: labelOf(name: name, shortCode: shortCode), code: shortCode)
        return withPayload ? "\(message)\n\(payload)" : message
    }

    private static func compare(_ a: Int64, _ b: Int64) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
}
