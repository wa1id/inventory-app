/**
 * The words Settings, Backup and Household use for states they only read:
 * the backup summary, why a backup failed, and how a joined phone is
 * described. Pure (no React Native), so it is tested in Node.
 */
import { ago } from '@/i18n/format';
import { strings } from '@/i18n/strings';
import type { SyncStatus } from '@/providers/SyncProvider';
import type { HouseholdDevice } from '@/services/household/devices';
import type { SyncFailureReason } from '@/services/sync/contract';

export interface Summary {
  value: string;
  tone: 'ink' | 'signal';
}

/**
 * The value on Settings' backup row. It says "Off" rather than nothing when
 * backup is disabled: an inventory that exists only on one phone is a fact
 * worth seeing without opening a submenu (`111b579:app/settings.tsx:35-39`).
 */
export function backupSummary(status: SyncStatus): Summary {
  const copy = strings.settings.backupSummary;
  switch (status.state) {
    case 'unavailable':
      return { value: copy.notConfigured, tone: 'ink' };
    case 'off':
      return { value: copy.off, tone: 'ink' };
    case 'working':
      return { value: copy.working, tone: 'ink' };
    case 'error':
      return { value: copy.attention, tone: 'signal' };
    case 'idle':
      return { value: status.lastBackupAt === null ? copy.notYetRun : copy.on, tone: 'ink' };
  }
}

/**
 * Whether Settings lists backup at all (#48). A phone that keeps its own
 * inventory always sees it; a joined phone keeps the household's inventory on
 * the home server, so it sees backup only once it has a backup account (and
 * the screen stays reachable for it). `unavailable` builds have nothing to
 * offer a joined phone either.
 */
export function showBackupRow(paired: boolean, status: SyncStatus): boolean {
  if (!paired) return true;
  return status.state !== 'off' && status.state !== 'unavailable';
}

/** Plain words for every way a backup or restore can fail (was `describe()`, `111b579:app/backup.tsx:13-36`). */
export function backupReason(reason: SyncFailureReason | 'malformed'): string {
  const copy = strings.backup.reasons;
  switch (reason) {
    case 'malformed':
      return copy.malformed;
    case 'offline':
      return copy.offline;
    case 'timeout':
      return copy.timeout;
    case 'unauthorized':
      return copy.unauthorized;
    case 'not_found':
      return copy.notFound;
    case 'quota_exceeded':
      return copy.quotaExceeded;
    case 'too_large':
      return copy.tooLarge;
    case 'corrupted':
      return copy.corrupted;
    case 'not_configured':
      return copy.notConfigured;
    default:
      return copy.other;
  }
}

/** "This phone", "Last used 3 days ago" or "Never used", under a phone's name. */
export function deviceMeta(device: HouseholdDevice, thisDeviceId: string, now: number): string {
  if (device.id === thisDeviceId) return strings.household.thisPhone;
  if (device.lastSeenAt === null) return strings.household.neverUsed;
  return strings.household.lastUsed(ago(device.lastSeenAt, now));
}

/** This phone first, then the others in the order they joined (the server's order). */
export function sortDevices(
  devices: readonly HouseholdDevice[],
  thisDeviceId: string,
): HouseholdDevice[] {
  const mine = devices.filter((device) => device.id === thisDeviceId);
  const others = devices.filter((device) => device.id !== thisDeviceId);
  return [...mine, ...others];
}
