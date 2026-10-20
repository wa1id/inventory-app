import Observation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStrings

// RN: app/backup.tsx (03 §9), on top of SyncModel, with the U6 sync fixes on screen: an
// unreadable keychain offers Try again instead of Turn on and Restore (03 B8), and an empty
// inventory over existing backups offers to restore the saved copy (03 B12).

/// The recovery code on screen, once after Turn on or again from "Show recovery code"
/// (RN `RevealedCode`).
public struct BackupRevealedCode: Sendable, Hashable {
    /// The code as stored: 26 characters, no hyphens.
    public var code: String
    /// Turn on found a code already on this phone (one it could not read earlier) and carries on
    /// with it: `L10n.Backup.keptExistingCode` shows above the code.
    public var keptExistingCode: Bool

    public init(code: String, keptExistingCode: Bool = false) {
        self.code = code
        self.keptExistingCode = keptExistingCode
    }

    /// `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-X`, as it is written down and shared (RN `formatRecoveryCode`).
    public var formatted: String { RecoveryCode.format(code) }

    /// Spelt out for VoiceOver, so it can be written down letter by letter (RN `spellCode`).
    public var spoken: String { spellCode(formatted) }

    /// The formatted code broken only between groups, for a box too narrow for one line (RN let
    /// the text wrap anywhere at a hyphen, which could leave "-8" alone on the last line).
    public struct Lines: Sendable, Hashable {
        /// `89144-GJ289-144GJ-28914-4GJ28-8`.
        public var one: String
        /// The first half of the groups, then the rest: `89144-GJ289-144GJ-` / `28914-4GJ28-8`.
        public var two: String
        /// A group a line, each but the last ending in its hyphen.
        public var each: String
    }

    /// ``formatted`` on one line, two even lines, or a group a line.
    public var formattedLines: Lines {
        let groups = formatted.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        let half = (groups.count + 1) / 2
        let first = groups.prefix(half).joined(separator: "-")
        let rest = groups.dropFirst(half).joined(separator: "-")
        return Lines(
            one: formatted,
            two: rest.isEmpty ? first : "\(first)-\n\(rest)",
            each: groups.joined(separator: "-\n")
        )
    }
}

/// Which body the Backup screen shows, chosen in RN's order (03 §9.2) with the B8 state added.
public enum BackupScreenBody: Sendable, Hashable {
    /// No backup service in this build: one info banner.
    case unavailable
    /// The code, to write down or share.
    case revealed(BackupRevealedCode)
    /// "Backup is on": the status card, Back up now and the way back to the code.
    case on
    /// The keychain refused to read this phone's code (03 B8): Try again, no Turn on or Restore.
    case unreadable
    /// "Keep a copy off this phone" (Turn on) and "Restore from a recovery code".
    case off
}

/// The Backup screen (RN app/backup.tsx): turn backup on or restore with a code; write the code
/// down; see that it is on, back up now, or show the code again.
///
/// Backup's state is ``SyncModel``'s, shared by the whole app; this model holds only what the
/// screen adds: the code on screen, the code being typed, which action runs, and why the last one
/// failed. One guard covers Turn on, Restore and restoring the saved copy, set before a
/// confirmation shows so a second tap meanwhile does nothing (RN `busyRef`); Back up now and Try
/// again have their own (RN `runningRef`).
@MainActor
@Observable
public final class BackupScreenModel {
    /// Which action runs (RN `busy`).
    public enum Busy: Sendable, Hashable {
        /// Turn on.
        case enable
        /// Restore… with a typed code.
        case restore
        /// "Restore the saved copy…" (03 B12).
        case restoreOffer
    }

    /// The code on screen; nil once "I have saved it" is pressed. Leaving the screen forgets it
    /// (the code stays reachable through "Show recovery code").
    public private(set) var revealed: BackupRevealedCode?
    public private(set) var busy: Busy?
    /// A restore with a typed code is running: the form stays up meanwhile (RN `restoring`).
    public private(set) var isRestoring = false
    /// Why Turn on made nothing, in plain words: a warning banner above the button.
    public private(set) var enableFailure: String?
    /// The recovery code as typed, normalised.
    public private(set) var code = ""
    /// Under the code field: a mistyped code, or why the restore failed (the code stays).
    public private(set) var codeError: String?
    /// Why restoring the saved copy failed (`L10n.Backup.RestoreOffer.failedTitle` over it).
    public private(set) var restoreOfferFailure: String?
    /// A restore that stopped because this phone already backs up under another code
    /// (`L10n.Backup.accountAlreadyOnThisPhone`), shown on "Backup is on" until put away.
    public private(set) var notice: String?
    /// Try again on the unreadable keychain is reading.
    public private(set) var isRetryingAccountLoad = false

    @ObservationIgnored public let sync: SyncModel
    @ObservationIgnored private let toasts: any ToastPresenting
    @ObservationIgnored private let confirmer: any ConfirmPresenting
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let announce: @MainActor @Sendable (String) -> Void
    @ObservationIgnored private var busyGuard = false
    @ObservationIgnored private var backingUp = false

    /// - Parameters:
    ///   - sync: the app's backup model (`app.sync`).
    ///   - announce: an interrupting VoiceOver announcement (`app.platform.announce`).
    public init(
        sync: SyncModel,
        toasts: any ToastPresenting,
        confirm: any ConfirmPresenting,
        haptics: @escaping HapticPlayer,
        announce: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.sync = sync
        self.toasts = toasts
        self.confirmer = confirm
        self.haptics = haptics
        self.announce = announce
    }

    // MARK: - What shows

    /// RN app/backup.tsx:72-80: unavailable, then the revealed code, then "on" when the status
    /// has an account and no typed restore runs, then the unreadable keychain, then "off".
    public var body: BackupScreenBody {
        if sync.status == .unavailable { return .unavailable }
        if let revealed { return .revealed(revealed) }
        if sync.status.account != nil, !isRestoring { return .on }
        if sync.isAccountUnreadable { return .unreadable }
        return .off
    }

    /// Turn on shows its spinner.
    public var isTurningOn: Bool { busy == .enable }
    /// Turn on takes no press while a typed restore runs.
    public var turnOnDisabled: Bool { busy == .restore }
    /// Restore… shows its spinner.
    public var isRestoringFromCode: Bool { busy == .restore }
    /// Restore… takes no press with nothing typed, or while Turn on runs.
    public var restoreDisabled: Bool { code.isEmpty || busy == .enable }

    /// The status card's line (03 §9.4): "Restoring…" while the saved copy comes back, else
    /// "Backing up…", "No backup has finished yet." or "Last backup 5 minutes ago"; nil while the
    /// error banner speaks instead.
    public func lastLine(now: Int64) -> String? {
        if busy == .restoreOffer { return L10n.Backup.RestoreOffer.working }
        return sync.status.lastBackupLine(now: now)
    }

    /// Why the last backup the person asked for failed: the warning banner above the card,
    /// with Try again (`L10n.Backup.errorTitle` over it).
    public var errorReason: String? {
        if case .error(_, let reason) = sync.status { return reason.backupMessage }
        return nil
    }

    /// Back up now is hidden while the error banner offers Try again.
    public var showsBackUpNow: Bool { errorReason == nil }

    /// Back up now (and Try again) shows its spinner while a backup runs.
    public var isBackingUp: Bool {
        if case .working = sync.status { return true }
        return false
    }

    /// Whether "Restore the saved copy…" is offered (03 B12): a backup was held back because this
    /// phone's inventory is empty while its account has backups. Once something is added here the
    /// offer goes (its copy would no longer be true, and the next pass backs the inventory up),
    /// except while that restore runs or just failed.
    ///
    /// - Parameter localInventoryHasRows: whether this phone's database holds anything beyond the
    ///   drop zone (`BackupService.hasUserRows`), nil until read.
    public func showsRestoreOffer(localInventoryHasRows: Bool?) -> Bool {
        guard sync.suggestsRestore, sync.status.account != nil else { return false }
        return localInventoryHasRows != true || busy == .restoreOffer || restoreOfferFailure != nil
    }

    /// What VoiceOver hears when the status changes (RN app/backup.tsx:307-316): a finished
    /// backup is said once, with its line, while "Backup is on" shows; the line itself is not
    /// announced as it ticks, and a failure is said by its banner. A finished restore of the
    /// saved copy says nothing here: its toast does. Nor does the first backup of Turn on, which
    /// ends with the code on screen (RN's status card was gone by then, with its announcement),
    /// so nothing talks over "Write this down now".
    public func statusAnnouncement(from old: SyncStatus, to new: SyncStatus, now: Int64) -> String? {
        guard case .working = old, case .idle = new else { return nil }
        guard busy != .restoreOffer, busy != .enable, revealed == nil else { return nil }
        return new.lastBackupLine(now: now)
    }

    // MARK: - Backup off

    /// "Turn on backup" (RN `turnOn`, app/backup.tsx:114-142): creates the account and its first
    /// backup, then shows its code at once. A first backup that failed still shows the code (the
    /// account exists and keeps retrying; the status then carries the reason and Try again). An
    /// account that was already stored is kept and its code shown with a note. Nothing made
    /// (no database yet, or the keychain refused) is said above the button; a keychain that cannot
    /// be read turns the screen into its "cannot be checked" state instead.
    public func turnOn() async {
        guard !busyGuard else { return }
        busyGuard = true
        busy = .enable
        enableFailure = nil
        defer {
            busyGuard = false
            busy = nil
        }
        switch await sync.enable() {
        case .enabled(let account), .backupFailed(let account, _):
            revealed = BackupRevealedCode(code: account.recoveryCode)
        case .backupHeldBack(let account):
            revealed = BackupRevealedCode(code: account.recoveryCode, keptExistingCode: true)
        case .notStarted(let reason):
            enableFailure = reason.backupMessage
        }
    }

    /// The code field changed: normalised (small letters, hyphens, spaces and look-alikes are
    /// fine), and its error cleared.
    public func updateCode(_ typed: String) {
        code = normaliseCode(typed)
        codeError = nil
    }

    /// "Restore…" (RN `restore`, app/backup.tsx:144-192). A mistyped code is said under the field
    /// and never reaches the question. Otherwise it asks before replacing what is on this phone,
    /// then restores; the code is cleared on success (toast and success haptic) and kept under a
    /// reason on failure (error haptic). A restore that found another code already on this phone
    /// changes nothing and says so on "Backup is on".
    public func restore() async {
        guard !busyGuard else { return }
        if let problem = codeProblem(code) {
            switch problem {
            case .chars(let chars): codeError = L10n.Backup.badChars(chars: chars)
            case .length: codeError = BackupFailureReason.malformed.message
            }
            haptics(.error)
            return
        }
        // Held through the question, so neither button starts anything while it is up; the
        // buttons only look busy once it is answered.
        busyGuard = true
        defer { busyGuard = false }
        guard await confirmRestore() else { return }

        busy = .restore
        codeError = nil
        isRestoring = true
        defer {
            busy = nil
            isRestoring = false
        }
        switch await sync.restoreFromCode(code) {
        case .restored:
            code = ""
            haptics(.success)
            // The inventory is back; a keychain that refused the code leaves backup off.
            let message = sync.account == nil ? L10n.Backup.restoredCodeNotKept : L10n.Backup.restored
            toasts.show(ToastOptions(message: message))
        case .failed(let reason):
            codeError = reason.message
            haptics(.error)
        case .accountAlreadyOnThisPhone:
            notice = L10n.Backup.accountAlreadyOnThisPhone
            haptics(.warning)
        }
    }

    // MARK: - Backup on

    /// "Back up now", and Try again on the error banner (RN `runNow`): one at a time, since
    /// both can be pressed before the status says "working". A failure arrives as the status.
    public func backUpNow() async {
        guard !backingUp else { return }
        backingUp = true
        defer { backingUp = false }
        _ = await sync.backupNow()
    }

    /// "Show recovery code".
    public func showCode() {
        guard let account = sync.status.account else { return }
        revealed = BackupRevealedCode(code: account.recoveryCode)
    }

    /// "Restore the saved copy…" (03 B12): asks first, exactly as Restore… does, since this
    /// phone's inventory may no longer be empty; then restores the newest backup of the account
    /// already on this phone (the keychain is not touched). Success is the restored toast and
    /// the success haptic; a failure is said under the offer, which stays.
    public func restoreSavedCopy() async {
        guard !busyGuard else { return }
        busyGuard = true
        defer { busyGuard = false }
        guard await confirmRestore() else { return }

        busy = .restoreOffer
        restoreOfferFailure = nil
        defer { busy = nil }
        switch await sync.restoreFromAccount() {
        case .restored:
            haptics(.success)
            toasts.show(ToastOptions(message: L10n.Backup.restored))
        case .failed(let reason):
            restoreOfferFailure = reason.message
            haptics(.error)
        case .accountAlreadyOnThisPhone:
            // restoreFromAccount never compares codes.
            restoreOfferFailure = BackupFailureReason.sync(.serverError).message
            haptics(.error)
        }
    }

    /// Puts the "already backs up under another code" notice away.
    public func dismissNotice() {
        notice = nil
    }

    // MARK: - Revealed code

    /// "I have saved it": back to whatever the status says.
    public func saved() {
        revealed = nil
    }

    // MARK: - Unreadable keychain

    /// Try again on "Backup cannot be checked right now" (03 B8): reads the keychain again. A read
    /// that is refused again is said once more (the notice itself has not changed, so it would
    /// not be announced) with the error haptic.
    public func retryAccountLoad() async {
        guard !isRetryingAccountLoad else { return }
        isRetryingAccountLoad = true
        defer { isRetryingAccountLoad = false }
        await sync.retryAccountLoad()
        if sync.isAccountUnreadable, sync.account == nil {
            haptics(.error)
            announce(L10n.Backup.Unreadable.title)
        }
    }

    // MARK: - Internals

    /// RN app/backup.tsx:158-162: destructive "Replace", Cancel; dismissing counts as Cancel.
    private func confirmRestore() async -> Bool {
        await confirmer.confirm(ConfirmOptions(
            title: L10n.Backup.restoreConfirmTitle,
            body: L10n.Backup.restoreConfirmBody,
            confirmLabel: L10n.Backup.restoreConfirm
        ))
    }
}
