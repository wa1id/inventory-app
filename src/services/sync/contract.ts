/**
 * Wire contract v1 between the app and the sync service.
 *
 * Must stay byte-compatible with `worker/src/contract.ts`. Treat the two files
 * as one unit — the app validates everything it receives and falls back to
 * local-only when it sees a shape it does not understand, so a mismatch costs
 * backups rather than corrupting them, but it still costs backups.
 */
export const SYNC_CONTRACT_VERSION = 1;

/**
 * A recovery code is 16 CSPRNG bytes. 128 bits is far past guessable, and it
 * encodes to 26 base32 characters — five groups of five plus one, which is
 * about as much as anyone will copy off a screen without a mistake.
 */
export const SECRET_BYTES = 16;
export const RECOVERY_CODE_LENGTH = 26;

export const MAX_PHOTO_BYTES = 4 * 1024 * 1024;
export const MAX_BACKUP_BYTES = 32 * 1024 * 1024;
export const MAX_ACCOUNT_BYTES = 2 * 1024 * 1024 * 1024;
export const BACKUP_RETENTION = 5;

export interface BackupSummary {
  id: string;
  size: number;
  capturedAt: number;
  schemaVersion: number;
}

/**
 * Why every sync failure is a value rather than an exception.
 *
 * Sync is the app's only networked feature and it is never the point of what
 * the user is doing — they are adding an item or looking one up. A failure to
 * reach the service must never interrupt that, so callers get a result they can
 * ignore rather than an error they must catch.
 */
export type SyncFailureReason =
  | 'not_configured'
  | 'no_account'
  | 'offline'
  | 'timeout'
  | 'unauthorized'
  | 'quota_exceeded'
  | 'too_large'
  | 'not_found'
  | 'corrupted'
  | 'server_error'
  | 'malformed_response';

export type SyncResult<T> =
  { status: 'success'; value: T } | { status: 'failed'; reason: SyncFailureReason };

export function isBackupSummary(value: unknown): value is BackupSummary {
  if (typeof value !== 'object' || value === null) return false;
  const candidate = value as Record<string, unknown>;
  return (
    typeof candidate.id === 'string' &&
    typeof candidate.size === 'number' &&
    typeof candidate.capturedAt === 'number' &&
    typeof candidate.schemaVersion === 'number'
  );
}

/** Validates a list response before any of it reaches the UI. */
export function parseBackupList(body: unknown): BackupSummary[] | null {
  if (typeof body !== 'object' || body === null) return null;
  const candidate = body as Record<string, unknown>;

  if (candidate.contractVersion !== SYNC_CONTRACT_VERSION) return null;
  if (!Array.isArray(candidate.backups)) return null;
  if (!candidate.backups.every(isBackupSummary)) return null;

  return candidate.backups as BackupSummary[];
}
