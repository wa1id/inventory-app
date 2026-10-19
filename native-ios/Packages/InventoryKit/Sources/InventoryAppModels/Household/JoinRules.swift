import InventoryCore
import InventoryStrings

// RN: src/ui/household/join.ts (04 §13.1). Joining a household as plain logic: checking a typed
// code and name before anything is sent, and the phone name to suggest. `codeProblem`,
// `joinFailure` and `serverHost` from the same file live in InventoryCore (Account/Codes.swift,
// Errors/JoinFailure.swift), next to the code normalisation they share with the backup screen.

/// What is wrong with the join form, field by field (RN `JoinErrors`). Each message replaces
/// the field's hint.
public struct JoinErrors: Sendable, Hashable {
    /// Under the household code.
    public var code: String?
    /// Under the phone's name.
    public var name: String?

    public init(code: String? = nil, name: String? = nil) {
        self.code = code
        self.name = name
    }

    /// Nothing to say: the form may be sent.
    public var isEmpty: Bool { code == nil && name == nil }
}

/// Checks the form on press, not while typing, so a half-typed code is never an error
/// (RN `validateJoin`, join.ts:40-50).
///
/// An empty code asks for one and says where it comes from (rather than "this one has 0");
/// otherwise characters no code uses come before a wrong length. A name that is blank after
/// trimming is missing.
///
/// - Parameter normalisedCode: the code as the field keeps it (``normaliseCode(_:)``).
public func validateJoin(_ normalisedCode: String, name: String) -> JoinErrors {
    var errors = JoinErrors()
    if normalisedCode.isEmpty {
        errors.code = L10n.Join.codeRequired
    } else {
        switch codeProblem(normalisedCode) {
        case .chars(let chars): errors.code = L10n.Join.badChars(chars: chars)
        case .length(let count): errors.code = L10n.Join.wrongLength(count: count)
        case nil: break
        }
    }
    if name.jsTrimmed().isEmpty { errors.name = L10n.Join.nameRequired }
    return errors
}

/// The name to prefill: the phone's own name ("Anna’s iPhone") when it has a real one, else
/// nothing, so the field asks for one instead of suggesting a name every phone would share
/// (RN `suggestedPhoneName`, join.ts:53-63).
///
/// iOS 16+ reports the generic "iPhone" without the user-assigned-device-name entitlement,
/// which the app does not have, so on device this is usually empty.
///
/// - Parameter deviceName: `UIDevice.current.name` (RN `Constants.deviceName`).
public func suggestedPhoneName(_ deviceName: String?) -> String {
    let name = (deviceName ?? "").jsTrimmed()
    return genericPhoneNames.contains(name.jsLowercased()) ? "" : name
}

/// Names that say nothing about whose phone it is (RN `GENERIC_NAMES`).
private let genericPhoneNames: Set<String> = ["iphone", "ipad", "android"]
