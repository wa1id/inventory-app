/**
 * Wire contract v1 between the Inventory app and this service.
 *
 * Must stay byte-compatible with the app's `src/services/sync/contract.ts`.
 * Treat the two files as one unit — the app validates everything it receives
 * and degrades to local-only when it sees a shape it does not understand, so a
 * mismatch costs backups rather than corrupting them, but it still costs
 * backups.
 */
export const SYNC_CONTRACT_VERSION = 1;

/**
 * A recovery code is 16 CSPRNG bytes. 128 bits is far past guessable, and it
 * encodes to 26 base32 characters — five groups of five plus one, which is
 * about as much as anyone will copy off a screen without a mistake.
 */
export const SECRET_BYTES = 16;
export const RECOVERY_CODE_LENGTH = 26;

/**
 * Photos are capped well above what the app produces. `storeItemPhoto` resizes
 * to 1600px at quality 0.7, which lands under 400 KB for a normal photo; 4 MB
 * leaves room for a pathological one without letting the endpoint be used as
 * general-purpose file hosting.
 */
export const MAX_PHOTO_BYTES = 4 * 1024 * 1024;

/**
 * Snapshots are buffered in memory to hash and measure them, so this is bounded
 * by the Worker's 128 MB rather than by anything about SQLite. An inventory
 * database without photo blobs is measured in single-digit megabytes; a user
 * who somehow exceeds this has outgrown whole-file snapshots and needs
 * incremental sync, which is a different feature.
 */
export const MAX_BACKUP_BYTES = 32 * 1024 * 1024;

/** Total bytes one account may hold before writes are refused. */
export const MAX_ACCOUNT_BYTES = 2 * 1024 * 1024 * 1024;

/**
 * Snapshots kept per account, newest first.
 *
 * More than one because the failure this protects against is not only a lost
 * phone — it is also a bad edit or a corrupt write that gets faithfully backed
 * up. One snapshot would replicate that damage and call it durability.
 */
export const BACKUP_RETENTION = 5;

export interface BackupSummary {
  /** Opaque handle used to fetch this specific snapshot. */
  id: string;
  size: number;
  /** Epoch millis, taken from the client clock at snapshot time. */
  capturedAt: number;
  /** `user_version` of the snapshot, so an older app can refuse a newer schema. */
  schemaVersion: number;
}

export interface BackupListResponse {
  contractVersion: number;
  backups: BackupSummary[];
}

export interface UsageResponse {
  contractVersion: number;
  bytes: number;
  objects: number;
  limitBytes: number;
}

export interface ErrorResponse {
  error: string;
}

/**
 * Photo ids are the app's `newId()` output, and they are pasted straight into
 * an R2 key. Validating the shape is what stops a crafted id from walking out
 * of the account prefix with `../` or colliding with the metadata namespace.
 */
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function isValidPhotoId(value: string): boolean {
  return UUID_PATTERN.test(value);
}

/** Snapshot ids are the epoch millis the client captured at. */
export function isValidBackupId(value: string): boolean {
  return /^[0-9]{10,16}$/.test(value);
}

export function photoKey(accountId: string, photoId: string): string {
  return `photos/${accountId}/${photoId}.jpg`;
}

export function backupKey(accountId: string, backupId: string): string {
  return `backups/${accountId}/${backupId}.db`;
}

export function backupPrefix(accountId: string): string {
  return `backups/${accountId}/`;
}

export function accountPrefixes(accountId: string): string[] {
  return [`photos/${accountId}/`, `backups/${accountId}/`];
}

export function usageKey(accountId: string): string {
  return `meta/${accountId}/usage.json`;
}
