import InventoryCore
import InventoryNetwork
import InventoryStrings

/// The words Settings and Household use for states they only read: a settings row's value and
/// tone, and how each phone in the household is described (RN: src/ui/household/status.ts;
/// 04 §13.2). Pure, so the screens share it.
///
/// The backup half of status.ts lives with the sync model: `backupSummary` is
/// ``SyncStatus/settingsSummary`` (a ``Summary``), `showBackupRow` is
/// ``SyncStatus/showsSettingsRow(paired:)`` and `backupReason` is ``BackupFailureReason/message``.
public enum HouseholdStatus {
    /// A value on a settings row and the tone it is drawn in (RN `Summary`): the backup row
    /// (``SyncStatus/settingsSummary``) and the connection row
    /// (``HouseholdPairedModel/connectionSummary(_:)``).
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
