import Observation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryStrings

/// What has been typed into the join form so far, kept by a caller that may tear the form down
/// (onboarding's Back) (RN `JoinDraft`).
public struct JoinDraft: Sendable, Hashable {
    /// The normalised household code.
    public var code: String
    public var name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

/// A successful join (RN `Joined`).
public struct HouseholdJoined: Sendable, Hashable {
    /// The household's display name, for `L10n.Household.joined(household:)`.
    public var householdName: String
    /// This phone kept an inventory of its own before joining, so copying it in is on offer:
    /// the Household screen stays to show it instead of going back.
    public var hasImportOffer: Bool

    public init(householdName: String, hasImportOffer: Bool) {
        self.householdName = householdName
        self.hasImportOffer = hasImportOffer
    }
}

/// The join form: the household code, a name for this phone and "Join household", shared by
/// Settings › Household and onboarding (RN: src/ui/household/JoinForm.tsx; 04 §12.3).
///
/// The code field forgives small letters, missing hyphens and the look-alikes I, L and O; the
/// code and name are checked on press, not while typing. Whatever went wrong keeps both fields
/// as typed. The import offer is decided *before* pairing, from the raw local repositories,
/// because once joined every household write is mirrored into the local database and counting
/// afterwards would offer to copy the household's own data back.
///
/// The view binds the code field to ``formattedCode`` / ``updateCode(_:)`` and the name field to
/// ``name`` / ``updateName(_:)``, shows ``errors`` under the fields and ``failure`` as a warning
/// banner (`L10n.Join.offline` / `.other`, assertive), and runs ``join()`` from both the button
/// and the name field's return key in a task the form does not own: pairing swaps the Household
/// screen to its paired view before `join()` returns. Once validation passed, a cancelled task
/// does not stop a join half way: the offer count and the pairing run to the end, as in RN.
@MainActor
@Observable
public final class JoinFormModel {
    /// K18: the household is called "Home"; used only when the saved session cannot be read back
    /// (RN `FALLBACK_HOUSEHOLD_NAME`).
    public static let fallbackHouseholdName = "Home"

    /// The household code as typed, normalised (RN `normaliseCode`).
    public private(set) var code: String
    /// The phone's name as typed; trimmed only when sent.
    public private(set) var name: String
    /// Messages under the fields; each replaces its field's hint.
    public private(set) var errors = JoinErrors()
    /// The banner above the fields when the server did not answer (`offline`) or joining failed
    /// otherwise (`other`); a refused code is a code error instead.
    public private(set) var failure: JoinFailure?
    /// "Joining…" with a spinner on the button: this form's join, or another form's that still
    /// pairs this phone (``HouseholdModel/isJoining``), so a press here does nothing meanwhile.
    public var isJoining: Bool { household.isJoining }
    /// "Home server: inventory.wystudio.be", under the fields: always the build's origin, never a
    /// session's (RN JoinForm.tsx:198-202).
    public let serverCaption: String
    /// Called after every edit, so a caller can hand the draft back after recreating the form.
    @ObservationIgnored public var onDraftChange: (@MainActor (JoinDraft) -> Void)?

    @ObservationIgnored private let household: HouseholdModel
    @ObservationIgnored private let joinPreferences: HouseholdJoinPreferences
    @ObservationIgnored private let localRepositories: @MainActor () -> LocalRepositories?
    @ObservationIgnored private let invalidator: any InventoryInvalidating
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let telemetry: TelemetryReporter

    /// - Parameters:
    ///   - localRepositories: the raw local repositories, nil while the database is not ready
    ///     (the offer snapshot is then skipped, and no offer is ever made).
    ///   - householdOrigin: `AppConfig.householdOrigin`, for the caption.
    ///   - deviceName: `UIDevice.current.name`, filtered by ``suggestedPhoneName(_:)``.
    ///   - initialDraft: restores what was typed before the form was recreated.
    public init(
        household: HouseholdModel,
        joinPreferences: HouseholdJoinPreferences,
        localRepositories: @escaping @MainActor () -> LocalRepositories?,
        invalidator: any InventoryInvalidating,
        haptics: @escaping HapticPlayer,
        householdOrigin: String,
        deviceName: String?,
        initialDraft: JoinDraft? = nil,
        telemetry: TelemetryReporter = .shared
    ) {
        self.household = household
        self.joinPreferences = joinPreferences
        self.localRepositories = localRepositories
        self.invalidator = invalidator
        self.haptics = haptics
        self.telemetry = telemetry
        code = initialDraft?.code ?? ""
        name = initialDraft?.name ?? suggestedPhoneName(deviceName)
        serverCaption = L10n.Household.server(host: serverHost(householdOrigin))
    }

    /// What has been typed so far.
    public var draft: JoinDraft {
        JoinDraft(code: code, name: name)
    }

    /// The code as displayed: groups of five joined by hyphens.
    public var formattedCode: String {
        formatCode(code)
    }

    /// "12 of 26 characters" beside the code's label, only once something is typed; read on
    /// blur rather than live (RN CodeInput.tsx:42-54).
    public var codeCounter: String? {
        code.isEmpty ? nil : L10n.Forms.codeCounter(count: code.utf16.count, total: codeLength)
    }

    /// The code field changed: normalised, and it clears the code's error and the banner.
    public func updateCode(_ typed: String) {
        code = normaliseCode(typed)
        errors.code = nil
        failure = nil
        onDraftChange?(draft)
    }

    /// The name field changed: it clears only the name's error.
    public func updateName(_ typed: String) {
        name = typed
        errors.name = nil
        onDraftChange?(draft)
    }

    /// Checks the form, then joins (RN `join()`, JoinForm.tsx:102-143). Returns the household's
    /// name and whether an import offer is waiting, or nil when nothing was joined (the form then
    /// says why). A call while a join runs, this form's or another's, does nothing: pairing twice
    /// would register this phone twice.
    ///
    /// On success: the local inventory is counted for the import offer (only on a phone that
    /// never joined before), the phone pairs, `joinedBefore` is set, every list is invalidated
    /// and the success haptic plays. The caller shows `L10n.Household.joined(household:)` and
    /// moves on. On failure: `household_join_failed` is logged with the outcome, the status code
    /// and the error class; a refused code goes under the code field, anything else is the
    /// banner; the error haptic plays.
    public func join() async -> HouseholdJoined? {
        guard !household.isJoining else { return nil }
        let found = validateJoin(code, name: name)
        errors = found
        failure = nil
        guard found.isEmpty else {
            haptics(.error)
            return nil
        }

        guard household.beginJoining() else { return nil }
        defer { household.endJoining() }
        do {
            // The local database, never the shadowed repositories: what the phone holds of its
            // own, before any household write lands in it. In a task of its own, like the pairing
            // after it: a cancelled caller would fail the count (GRDB reads are cancellable), and
            // once paired the offer can never be made again.
            if let local = localRepositories() {
                let joinPreferences = joinPreferences
                await Task {
                    await joinPreferences.snapshotBeforeJoin {
                        (spaces: try await local.spaces.listWithCounts().count, items: try await local.items.countAll())
                    }
                }.value
            }
            try await household.pair(bootstrapSecret: code, deviceName: name.jsTrimmed())
            joinPreferences.markJoinedBefore()
            let householdName = household.session?.householdName ?? Self.fallbackHouseholdName
            let hasImportOffer = joinPreferences.importOffer != nil
            invalidator.invalidate()
            haptics(.success)
            return HouseholdJoined(householdName: householdName, hasImportOffer: hasImportOffer)
        } catch {
            let kind = joinFailure(error)
            telemetry.error("household_join_failed", [
                "outcome": .string(kind.rawValue),
                "statusCode": (error as? HouseholdHttpError).map { .int($0.status) } ?? .null,
                "errorClass": .string(errorClass(of: error)),
            ])
            // A refused code belongs under the code; no answer is about the connection.
            if kind == .refused {
                errors = JoinErrors(code: L10n.Join.refused)
            } else {
                failure = kind
            }
            haptics(.error)
            return nil
        }
    }
}
