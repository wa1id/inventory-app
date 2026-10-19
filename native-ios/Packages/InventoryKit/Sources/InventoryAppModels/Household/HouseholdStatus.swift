import InventoryCore
import InventoryNetwork
import InventoryStrings

/// The words Settings, Backup and Household use for states they only read: the backup row's
/// summary, whether a joined phone lists backup at all, why a backup failed, and how each phone
/// in the household is described (RN: src/ui/household/status.ts; 04 §13.2, 03 for the backup
/// parts). Pure, so the sync model and the screens share it.
public enum HouseholdStatus {
    /// A value on a settings row and the tone it is drawn in (RN `Summary`).
    public struct Summary: Sendable, Hashable {
        public var value: String
        public var tone: Tone

        public init(value: String, tone: Tone) {
            self.value = value
            self.tone = tone
        }
    }

    /// RN `'ink' | 'signal'`: plain, or the warning colour.
    public enum Tone: String, Sendable, Hashable {
        case ink
        case signal
    }

    /// What the backup row needs to know of the sync status (RN `SyncStatus['state']`, plus
    /// whether an idle account has backed up yet). The sync model maps its status onto this:
    /// `unavailable`, `off`, `working`, `error` one for one, and `idle` with its `lastBackupAt`.
    public enum BackupState: Sendable, Hashable {
        /// This build has no sync endpoint.
        case unavailable
        /// No backup account on this phone.
        case off
        /// An account; `lastBackupAt` is nil until the first backup (RN `lastBackupAt === null`).
        case idle(lastBackupAt: Double?)
        case working
        case error
    }

    /// Why a backup or restore failed: a typed code that is not a recovery code, or the sync
    /// client's reason (RN `SyncFailureReason | 'malformed'`).
    public enum BackupProblem: Sendable, Hashable {
        case malformed
        case sync(SyncFailureReason)
    }

    /// The value on Settings' backup row (RN `backupSummary`, status.ts:22-37). It says "Off"
    /// rather than nothing when backup is disabled: an inventory that exists only on one phone
    /// is a fact worth seeing without opening a submenu.
    public static func backupSummary(_ state: BackupState) -> Summary {
        switch state {
        case .unavailable: Summary(value: L10n.Settings.BackupSummary.notConfigured, tone: .ink)
        case .off: Summary(value: L10n.Settings.BackupSummary.off, tone: .ink)
        case .working: Summary(value: L10n.Settings.BackupSummary.working, tone: .ink)
        case .error: Summary(value: L10n.Settings.BackupSummary.attention, tone: .signal)
        case .idle(let lastBackupAt):
            Summary(value: lastBackupAt == nil ? L10n.Settings.BackupSummary.notYetRun : L10n.Settings.BackupSummary.on, tone: .ink)
        }
    }

    /// Whether Settings lists backup at all (RN `showBackupRow`, status.ts:45-48; #48).
    ///
    /// A phone that keeps its own inventory always sees it. A joined phone keeps the household's
    /// inventory on the home server, so it sees backup only once it has a backup account;
    /// `unavailable` builds have nothing to offer it either.
    public static func showBackupRow(paired: Bool, _ state: BackupState) -> Bool {
        guard paired else { return true }
        switch state {
        case .off, .unavailable: return false
        case .idle, .working, .error: return true
        }
    }

    /// Plain words for every way a backup or restore can fail; never a raw code
    /// (RN `backupReason`, status.ts:51-76).
    public static func backupReason(_ problem: BackupProblem) -> String {
        switch problem {
        case .malformed: return L10n.Backup.Reasons.malformed
        case .sync(let reason):
            switch reason {
            case .offline: return L10n.Backup.Reasons.offline
            case .timeout: return L10n.Backup.Reasons.timeout
            case .unauthorized: return L10n.Backup.Reasons.unauthorized
            case .notFound: return L10n.Backup.Reasons.notFound
            case .quotaExceeded: return L10n.Backup.Reasons.quotaExceeded
            case .tooLarge: return L10n.Backup.Reasons.tooLarge
            case .corrupted: return L10n.Backup.Reasons.corrupted
            case .notConfigured: return L10n.Backup.Reasons.notConfigured
            case .noAccount, .serverError, .malformedResponse: return L10n.Backup.Reasons.other
            }
        }
    }

    /// "This phone", "Last used 3 days ago" or "Never used", under a phone's name
    /// (RN `deviceMeta`, status.ts:78-82).
    ///
    /// "Never used" is effectively unreachable with the current server, which stamps
    /// `last_seen_at` at pairing (04 §2.3).
    ///
    /// - Parameter now: epoch milliseconds; the list refreshes it every minute.
    public static func deviceMeta(_ device: HouseholdDevice, thisDeviceId: String, now: Int64) -> String {
        if device.id == thisDeviceId { return L10n.Household.thisPhone }
        guard let lastSeenAt = device.lastSeenAt else { return L10n.Household.neverUsed }
        return L10n.Household.lastUsed(ago: Format.ago(lastSeenAt, now: now))
    }

    /// This phone first, then the others in the order they joined, the server's order
    /// (RN `sortDevices`, status.ts:85-92).
    public static func sortDevices(_ devices: [HouseholdDevice], thisDeviceId: String) -> [HouseholdDevice] {
        devices.filter { $0.id == thisDeviceId } + devices.filter { $0.id != thisDeviceId }
    }
}
