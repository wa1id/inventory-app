import InventoryNetwork
import InventoryServices
import InventoryStrings

// RN: `SyncStatus` (src/providers/SyncProvider.tsx:36-41) and the backup half of
// src/ui/household/status.ts (`backupSummary`, `showBackupRow`, `backupReason`), 03 §8.1, §9.

/// Where backup stands on this device, as Settings and the Backup screen show it.
public enum SyncStatus: Sendable, Equatable {
    /// No sync endpoint in this build; the app is purely local and the keychain is never read.
    case unavailable
    /// Configured, but this device has no account (or its keychain could not be read yet; see
    /// ``SyncModel/isAccountUnreadable``).
    case off
    /// On. `lastBackupAt` is the server time of the last backup this device recorded, in epoch
    /// milliseconds; nil when none has finished on this device.
    case idle(account: SyncAccount, lastBackupAt: Int64?)
    /// A backup the person asked for (or the first one) is running.
    case working(account: SyncAccount)
    /// The last backup the person asked for failed. `account` is nil only if none could be made.
    case error(account: SyncAccount?, reason: SyncFailureReason)

    /// The account for idle, working and error (the Backup screen shows "Backup on" for these).
    public var account: SyncAccount? {
        switch self {
        case .unavailable, .off: nil
        case .idle(let account, _), .working(let account): account
        case .error(let account, _): account
        }
    }

    /// The value on Settings' backup row (RN `backupSummary`). It says "Off" rather than nothing:
    /// an inventory that exists only on one phone is worth seeing without opening a submenu.
    public var settingsSummary: BackupSettingsSummary {
        typealias Copy = L10n.Settings.BackupSummary
        switch self {
        case .unavailable: return BackupSettingsSummary(value: Copy.notConfigured, tone: .ink)
        case .off: return BackupSettingsSummary(value: Copy.off, tone: .ink)
        case .working: return BackupSettingsSummary(value: Copy.working, tone: .ink)
        case .error: return BackupSettingsSummary(value: Copy.attention, tone: .signal)
        case .idle(_, let lastBackupAt):
            return BackupSettingsSummary(value: lastBackupAt == nil ? Copy.notYetRun : Copy.on, tone: .ink)
        }
    }

    /// Whether Settings lists backup at all (RN `showBackupRow`, #48). A phone that keeps its own
    /// inventory always sees it; a joined phone only once it has a backup account.
    public func showsSettingsRow(paired: Bool) -> Bool {
        guard paired else { return true }
        switch self {
        case .off, .unavailable: return false
        case .idle, .working, .error: return true
        }
    }

    /// Whether tapping the Settings row opens the Backup screen: not when unavailable, where the
    /// row is static (03 §9.1).
    public var opensBackupScreen: Bool { self != .unavailable }

    /// The Backup screen's status-card line (03 §9.4): "Backing up…", "No backup has finished
    /// yet.", "Last backup 5 minutes ago", or nil while an error banner shows instead.
    public func lastBackupLine(now: Int64) -> String? {
        switch self {
        case .working: L10n.Backup.working
        case .idle(_, nil): L10n.Backup.noBackupYet
        case .idle(_, let lastBackupAt?): L10n.Backup.lastBackup(ago: Format.ago(lastBackupAt, now: now))
        case .unavailable, .off, .error: nil
        }
    }
}

/// Settings' backup row value and how it reads (RN `Summary`): the same value-and-tone pair as
/// every settings row, so the Settings view draws it like the household's connection row.
public typealias BackupSettingsSummary = HouseholdStatus.Summary

/// Why a backup or restore failed, as the Backup screen words it (RN `SyncFailureReason |
/// 'malformed'`).
public enum BackupFailureReason: Sendable, Hashable {
    /// A typed recovery code that is not 26 valid characters.
    case malformed
    case sync(SyncFailureReason)

    /// Plain words for the failure; never a raw reason code (RN `backupReason`).
    public var message: String {
        typealias Copy = L10n.Backup.Reasons
        switch self {
        case .malformed: return Copy.malformed
        case .sync(let reason):
            switch reason {
            case .offline: return Copy.offline
            case .timeout: return Copy.timeout
            case .unauthorized: return Copy.unauthorized
            case .notFound: return Copy.notFound
            case .quotaExceeded: return Copy.quotaExceeded
            case .tooLarge: return Copy.tooLarge
            case .corrupted: return Copy.corrupted
            case .notConfigured: return Copy.notConfigured
            case .serverError, .malformedResponse, .noAccount: return Copy.other
            }
        }
    }
}

extension SyncFailureReason {
    /// ``BackupFailureReason/message`` for this reason (RN `backupReason(reason)`).
    public var backupMessage: String { BackupFailureReason.sync(self).message }
}

// MARK: - Outcomes the Backup screen acts on (03 §9.3-9.4)

/// What "Turn on backup" came to (RN `enable()` plus `turnOn()`'s follow-up).
public enum EnableBackupOutcome: Sendable, Equatable {
    /// The account exists and its first backup is stored: reveal its code.
    case enabled(SyncAccount)
    /// The account exists but its first backup failed: still reveal its code (RN `turnOn`
    /// reloads the account and reveals it); then the error banner offers Try again.
    case backupFailed(SyncAccount, SyncFailureReason)
    /// An account was already stored on this device (its keychain read had failed earlier), and
    /// the backup was held back because this inventory is empty while the account has backups
    /// (03 B8, B12). Reveal its code; the Backup screen then offers Restore.
    case backupHeldBack(SyncAccount)
    /// Nothing was created. `notConfigured` when the database is not open (RN); `serverError`
    /// when the keychain could not be read or written (RN showed `backupReason('server_error')`
    /// after the throw).
    case notStarted(SyncFailureReason)

    /// The account to reveal, if one exists.
    public var account: SyncAccount? {
        switch self {
        case .enabled(let account), .backupFailed(let account, _), .backupHeldBack(let account): account
        case .notStarted: nil
        }
    }
}

/// What "Back up now" came to. RN returned nothing; the status says the same.
public enum BackupNowOutcome: Sendable, Equatable {
    /// Stored; `lastBackupAt` is the server's `capturedAt`.
    case backedUp(lastBackupAt: Int64)
    case failed(SyncFailureReason)
    /// Held back: this inventory is empty and the account has backups (03 B12). Offer Restore.
    case heldBack
    /// No database or no account, so nothing ran (RN returned silently).
    case notStarted
}

/// What a restore came to (RN `restoreFromCode` result).
public enum RestoreOutcome: Sendable, Equatable {
    /// The backup is on this phone. RN showed the toast `backup.restored` and played the success
    /// haptic. Its account is now this phone's account (``SyncModel/status`` is `idle`), unless
    /// the keychain refused to store the code afterwards, in which case backup stays `off`.
    case restored
    /// Shown under the code field with ``BackupFailureReason/message``; the code stays.
    case failed(BackupFailureReason)
    /// A different account turned out to be stored on this phone already (its keychain read had
    /// failed or not finished). Nothing was restored or overwritten; the status now shows that
    /// account as on (03 B8).
    case accountAlreadyOnThisPhone
}
