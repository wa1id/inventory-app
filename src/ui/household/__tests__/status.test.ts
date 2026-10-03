import { strings } from '@/i18n/strings';
import type { SyncStatus } from '@/providers/SyncProvider';
import type { HouseholdDevice } from '@/services/household/devices';
import {
  backupReason,
  backupSummary,
  deviceMeta,
  showBackupRow,
  sortDevices,
} from '@/ui/household/status';

const account = { id: 'acc', recoveryCode: 'CODE' };
const NOW = Date.UTC(2026, 9, 2, 12);
const DAY = 24 * 60 * 60 * 1000;

const off: SyncStatus = { state: 'off' };
const unavailable: SyncStatus = { state: 'unavailable' };
const idle: SyncStatus = { state: 'idle', account, lastBackupAt: NOW - DAY };
const neverRun: SyncStatus = { state: 'idle', account, lastBackupAt: null };
const working: SyncStatus = { state: 'working', account };
const failed: SyncStatus = { state: 'error', account, reason: 'offline' };

describe('backupSummary', () => {
  it('always has a value, including Off', () => {
    const copy = strings.settings.backupSummary;
    expect(backupSummary(unavailable)).toEqual({ value: copy.notConfigured, tone: 'ink' });
    expect(backupSummary(off)).toEqual({ value: copy.off, tone: 'ink' });
    expect(backupSummary(working)).toEqual({ value: copy.working, tone: 'ink' });
    expect(backupSummary(neverRun)).toEqual({ value: copy.notYetRun, tone: 'ink' });
    expect(backupSummary(idle)).toEqual({ value: copy.on, tone: 'ink' });
  });

  it('marks a failed backup in signal', () => {
    expect(backupSummary(failed)).toEqual({
      value: strings.settings.backupSummary.attention,
      tone: 'signal',
    });
  });
});

describe('showBackupRow', () => {
  it('always shows backup on a phone that keeps its own inventory', () => {
    for (const status of [off, unavailable, idle, failed]) {
      expect(showBackupRow(false, status)).toBe(true);
    }
  });

  it('hides it on a joined phone that never set it up (#48)', () => {
    expect(showBackupRow(true, off)).toBe(false);
    expect(showBackupRow(true, unavailable)).toBe(false);
  });

  it('keeps it on a joined phone that has a backup account', () => {
    for (const status of [idle, neverRun, working, failed]) {
      expect(showBackupRow(true, status)).toBe(true);
    }
  });
});

describe('backupReason', () => {
  it('has plain words for every failure', () => {
    expect(backupReason('malformed')).toBe(strings.backup.reasons.malformed);
    expect(backupReason('not_found')).toBe(strings.backup.reasons.notFound);
    expect(backupReason('quota_exceeded')).toBe(strings.backup.reasons.quotaExceeded);
    expect(backupReason('server_error')).toBe(strings.backup.reasons.other);
    expect(backupReason('malformed_response')).toBe(strings.backup.reasons.other);
    expect(backupReason('no_account')).toBe(strings.backup.reasons.other);
  });

  it('never shows a raw reason code', () => {
    const reasons = [
      'malformed',
      'not_configured',
      'no_account',
      'offline',
      'timeout',
      'unauthorized',
      'quota_exceeded',
      'too_large',
      'not_found',
      'corrupted',
      'server_error',
      'malformed_response',
    ] as const;
    for (const reason of reasons) {
      expect(backupReason(reason)).not.toMatch(/_/);
    }
  });
});

describe('devices', () => {
  const mine: HouseholdDevice = { id: 'b', name: 'Anna’s iPhone', createdAt: 2, lastSeenAt: NOW };
  const owner: HouseholdDevice = {
    id: 'a',
    name: 'Kitchen iPhone',
    createdAt: 1,
    lastSeenAt: NOW - 3 * DAY,
  };
  const spare: HouseholdDevice = { id: 'c', name: 'Old iPad', createdAt: 3, lastSeenAt: null };

  it('describes each phone', () => {
    expect(deviceMeta(mine, 'b', NOW)).toBe(strings.household.thisPhone);
    expect(deviceMeta(owner, 'b', NOW)).toBe(strings.household.lastUsed('3 days ago'));
    expect(deviceMeta(spare, 'b', NOW)).toBe(strings.household.neverUsed);
  });

  it('lists this phone first, then the rest in the order they joined', () => {
    expect(sortDevices([owner, mine, spare], 'b').map((device) => device.id)).toEqual([
      'b',
      'a',
      'c',
    ]);
    expect(sortDevices([owner, spare], 'b').map((device) => device.id)).toEqual(['a', 'c']);
  });
});
