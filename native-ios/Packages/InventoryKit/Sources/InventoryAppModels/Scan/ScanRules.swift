import InventoryCore
import InventoryStrings

/// How to link a new label to the container someone picked (RN `BindPlan`).
public struct ScanBindPlan: Sendable, Hashable {
    /// False when the container already carries this very label: it was linked on another phone
    /// while this one was choosing, so there is nothing to write.
    public var write: Bool
    /// Asked first when the container's own sticker would stop working.
    public var confirm: ConfirmOptions?

    public init(write: Bool, confirm: ConfirmOptions?) {
        self.write = write
        self.confirm = confirm
    }
}

/// The rules behind scanning a label (the Scan tab) and opening one from a link (`/c/<token>`),
/// kept free of UI (06 §9.4).
// RN: src/ui/scan/scanRules.ts
public enum ScanRules {
    /// What a sentence calls a container: its name when it is not blank after a JS trim (the name
    /// as stored, untrimmed), or else the code on its label (RN `labelFor`).
    // RN: src/ui/scan/scanRules.ts:15-17
    public static func labelFor(name: String?, shortCode: String) -> String {
        if let name, !name.jsTrimmed().isEmpty { return name }
        return shortCode
    }

    /// ``labelFor(name:shortCode:)`` for a place-picker option.
    public static func labelFor(_ option: PlaceOption) -> String {
        labelFor(name: option.name, shortCode: option.shortCode)
    }

    /// ``labelFor(name:shortCode:)`` for a container.
    public static func labelFor(_ container: Container) -> String {
        labelFor(name: container.name, shortCode: container.shortCode)
    }

    /// The `token` of `/c/<token>` as one string: JS-trimmed, `""` when missing (RN `tokenParam`).
    /// Whatever it is, the repository decides whether it is one of ours.
    // RN: src/ui/scan/scanRules.ts:24-27
    public static func tokenParam(_ value: String?) -> String {
        value?.jsTrimmed() ?? ""
    }

    /// A link that repeats the parameter: the first one is the label.
    public static func tokenParam(_ values: [String]) -> String {
        tokenParam(values.first)
    }

    /// Linking a new label to the picked container (RN `planBind`). A container has one label at a
    /// time, so linking a new one retires the old sticker; that is asked first with the impact
    /// spelled out. The same token (JS lowercase on both sides) means it was linked meanwhile.
    ///
    /// - Parameter existingToken: The container's own label (`qr.getByContainer(id)?.token`), nil
    ///   when it has none.
    // RN: src/ui/scan/scanRules.ts:48-63
    public static func planBind(existingToken: String?, token: String, label: String) -> ScanBindPlan {
        guard let existingToken else { return ScanBindPlan(write: true, confirm: nil) }
        if existingToken.jsLowercased() == token.jsLowercased() { return ScanBindPlan(write: false, confirm: nil) }
        return ScanBindPlan(write: true, confirm: ConfirmOptions(
            title: L10n.DeepLink.replaceTitle(label: label),
            body: L10n.DeepLink.replaceBody(label: label),
            confirmLabel: L10n.DeepLink.replace
        ))
    }

    /// ``planBind(existingToken:token:label:)`` from the container's binding.
    public static func planBind(existing: QrBinding?, token: String, label: String) -> ScanBindPlan {
        planBind(existingToken: existing?.token, token: token, label: label)
    }

    /// The error toast when a label could not be linked, in plain words (RN `linkFailureMessage`).
    // RN: src/ui/scan/scanRules.ts:69-73
    public static func linkFailureMessage(_ cause: any Error) -> String {
        let kind = describeError(cause, context: .label, subject: .container).kind
        if kind == .gone { return L10n.DeepLink.containerGone }
        return L10n.DeepLink.linkFailed(offline: kind == .offline)
    }
}
