import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Crypto from 'expo-crypto';

import { asBufferSource, toHex } from '@/core/bytes';
import { LATEST_SCHEMA_VERSION, migrate } from '@/db/migrations';
import type { SqlDatabase } from '@/db/types';
import { logError, logEvent } from '@/services/telemetry';

import type { SyncClient } from './client';
import { MAX_BACKUP_BYTES, type BackupSummary, type SyncResult } from './contract';

const LAST_BACKUP_KEY = 'sync.lastBackupAt.v1';

/**
 * Shortest gap between automatic backups.
 *
 * Snapshots are whole-database, so backing up after every edit would re-upload
 * the entire inventory to record one changed field. Fifteen minutes bounds how
 * much work a crash can cost while keeping the cost of a busy session flat —
 * someone cataloguing a garage for an hour uploads four times, not four hundred.
 */
export const MIN_BACKUP_INTERVAL_MS = 15 * 60 * 1000;

export async function readSchemaVersion(db: SqlDatabase): Promise<number> {
  const row = await db.getFirstAsync<{ user_version: number }>('PRAGMA user_version');
  return row?.user_version ?? 0;
}

export async function lastBackupAt(): Promise<number | null> {
  try {
    const stored = await AsyncStorage.getItem(LAST_BACKUP_KEY);
    const parsed = stored ? Number(stored) : NaN;
    return Number.isFinite(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

async function recordBackup(at: number): Promise<void> {
  try {
    await AsyncStorage.setItem(LAST_BACKUP_KEY, String(at));
  } catch {
    // Only affects when the next automatic backup is due, and the worst case is
    // one extra upload.
  }
}

/** Hex SHA-256, so the service can reject a snapshot corrupted in transit. */
async function checksum(bytes: Uint8Array): Promise<string> {
  const digest = await Crypto.digest(Crypto.CryptoDigestAlgorithm.SHA256, asBufferSource(bytes));
  return toHex(new Uint8Array(digest));
}

/**
 * Snapshots the database and uploads it.
 *
 * The snapshot is taken first and completely, before any network call, so the
 * uploaded bytes are a single consistent moment rather than a database being
 * read while it is also being written.
 */
export async function runBackup(
  db: SqlDatabase,
  client: SyncClient,
): Promise<SyncResult<BackupSummary>> {
  if (!db.snapshotAsync) {
    return { status: 'failed', reason: 'not_configured' };
  }

  const startedAt = Date.now();
  let snapshot: Uint8Array;
  try {
    snapshot = await db.snapshotAsync();
  } catch (error) {
    logError('backup_snapshot_failed', {
      durationMs: Date.now() - startedAt,
      errorClass: error instanceof Error ? error.name : 'unknown',
    });
    return { status: 'failed', reason: 'server_error' };
  }

  // Checked here as well as server-side: refusing locally saves uploading tens
  // of megabytes only to be rejected, on what may be a metered connection.
  if (snapshot.byteLength > MAX_BACKUP_BYTES) {
    logError('backup_too_large', { byteSize: snapshot.byteLength });
    return { status: 'failed', reason: 'too_large' };
  }

  const schemaVersion = await readSchemaVersion(db);
  const result = await client.uploadBackup(snapshot, schemaVersion, await checksum(snapshot));

  if (result.status === 'success') {
    await recordBackup(result.value.capturedAt);
  }
  return result;
}

/** Runs a backup only if enough time has passed since the last one. */
export async function maybeBackup(
  db: SqlDatabase,
  client: SyncClient,
  now: number = Date.now(),
): Promise<SyncResult<BackupSummary> | null> {
  const last = await lastBackupAt();
  if (last !== null && now - last < MIN_BACKUP_INTERVAL_MS) return null;
  return runBackup(db, client);
}

/**
 * Replaces local data with a snapshot from the service.
 *
 * Refuses a snapshot written by a newer build. Migrations only run forwards, so
 * restoring a newer schema into an older app would leave it holding tables it
 * cannot read and cannot migrate its way out of — the failure would surface
 * later as corruption rather than here as a refusal.
 *
 * A snapshot from an *older* build is fine and expected: it is migrated up
 * immediately, using the same path an in-place app upgrade takes.
 */
export async function restoreBackup(
  db: SqlDatabase,
  client: SyncClient,
  backupId: string = 'latest',
): Promise<SyncResult<{ schemaVersion: number }>> {
  if (!db.restoreAsync) {
    return { status: 'failed', reason: 'not_configured' };
  }

  const startedAt = Date.now();
  const downloaded = await client.downloadBackup(backupId);
  if (downloaded.status === 'failed') return downloaded;

  const { bytes, schemaVersion } = downloaded.value;

  if (schemaVersion > LATEST_SCHEMA_VERSION) {
    logError('restore_rejected', { schemaVersion, outcome: 'newer_schema' });
    return { status: 'failed', reason: 'corrupted' };
  }

  try {
    await db.restoreAsync(bytes);
    // The snapshot may predate this build's schema; bring it forward before any
    // repository touches it.
    await migrate(db);
  } catch (error) {
    logError('restore_failed', {
      durationMs: Date.now() - startedAt,
      errorClass: error instanceof Error ? error.name : 'unknown',
    });
    return { status: 'failed', reason: 'corrupted' };
  }

  logEvent('restore_succeeded', {
    durationMs: Date.now() - startedAt,
    byteSize: bytes.byteLength,
    schemaVersion,
  });

  return { status: 'success', value: { schemaVersion } };
}
