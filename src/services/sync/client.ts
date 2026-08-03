import { appConfig } from '@/services/config';
import { logError, logEvent } from '@/services/telemetry';

import {
  SYNC_CONTRACT_VERSION,
  parseBackupList,
  type BackupSummary,
  type SyncFailureReason,
  type SyncResult,
} from './contract';

export interface SyncClientOptions {
  /** The account's recovery code, used as the bearer credential. */
  recoveryCode: string;
  endpoint?: string | null;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}

/**
 * HTTP client for the photo and backup service.
 *
 * Nothing here throws. Every method resolves to a `SyncResult`, because sync is
 * never what the user is actually doing — losing the network in the middle of a
 * backup should be invisible to someone in the middle of adding an item.
 *
 * The recovery code goes in the `Authorization` header and nowhere else: never
 * a query string, never a log line, never a telemetry payload. A URL ends up in
 * proxy logs and crash reports, and this credential is the whole account.
 */
export function createSyncClient(options: SyncClientOptions) {
  const endpoint = options.endpoint === undefined ? appConfig.syncEndpoint : options.endpoint;
  const doFetch = options.fetchImpl ?? globalThis.fetch;
  const timeoutMs = options.timeoutMs ?? appConfig.syncTimeoutMs;

  async function send(
    path: string,
    init: RequestInit & { headers?: Record<string, string> } = {},
  ): Promise<SyncResult<Response>> {
    if (!endpoint) return { status: 'failed', reason: 'not_configured' };

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);

    try {
      const response = await doFetch(`${endpoint}${path}`, {
        ...init,
        headers: {
          Authorization: `Bearer ${options.recoveryCode}`,
          'X-Contract-Version': String(SYNC_CONTRACT_VERSION),
          ...(appConfig.syncKey ? { 'x-inventory-key': appConfig.syncKey } : {}),
          ...init.headers,
        },
        signal: controller.signal,
      });

      if (!response.ok) {
        return { status: 'failed', reason: classifyStatus(response.status) };
      }
      return { status: 'success', value: response };
    } catch (error) {
      return { status: 'failed', reason: classifyError(error) };
    } finally {
      clearTimeout(timer);
    }
  }

  return {
    get configured() {
      return endpoint !== null;
    },

    async uploadPhoto(photoId: string, bytes: Uint8Array): Promise<SyncResult<void>> {
      const startedAt = Date.now();
      const result = await send(`/v1/photos/${photoId}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'image/jpeg' },
        body: bytes as unknown as BodyInit,
      });

      if (result.status === 'failed') {
        logError('photo_upload_failed', {
          outcome: result.reason,
          latencyMs: Date.now() - startedAt,
          byteSize: bytes.byteLength,
        });
        return result;
      }

      logEvent('photo_uploaded', {
        latencyMs: Date.now() - startedAt,
        byteSize: bytes.byteLength,
      });
      return { status: 'success', value: undefined };
    },

    async downloadPhoto(photoId: string): Promise<SyncResult<Uint8Array>> {
      const result = await send(`/v1/photos/${photoId}`);
      if (result.status === 'failed') return result;

      try {
        const buffer = await result.value.arrayBuffer();
        return { status: 'success', value: new Uint8Array(buffer) };
      } catch {
        return { status: 'failed', reason: 'malformed_response' };
      }
    },

    async deletePhoto(photoId: string): Promise<SyncResult<void>> {
      const result = await send(`/v1/photos/${photoId}`, { method: 'DELETE' });
      if (result.status === 'failed') return result;
      return { status: 'success', value: undefined };
    },

    async uploadBackup(
      snapshot: Uint8Array,
      schemaVersion: number,
      checksum?: string,
    ): Promise<SyncResult<BackupSummary>> {
      const startedAt = Date.now();
      const result = await send('/v1/backups', {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/vnd.sqlite3',
          'x-snapshot-schema-version': String(schemaVersion),
          ...(checksum ? { 'x-snapshot-sha256': checksum } : {}),
        },
        body: snapshot as unknown as BodyInit,
      });

      if (result.status === 'failed') {
        logError('backup_upload_failed', {
          outcome: result.reason,
          latencyMs: Date.now() - startedAt,
          byteSize: snapshot.byteLength,
          schemaVersion,
        });
        return result;
      }

      try {
        const body = (await result.value.json()) as BackupSummary;
        logEvent('backup_uploaded', {
          latencyMs: Date.now() - startedAt,
          byteSize: snapshot.byteLength,
          schemaVersion,
        });
        return { status: 'success', value: body };
      } catch {
        return { status: 'failed', reason: 'malformed_response' };
      }
    },

    async listBackups(): Promise<SyncResult<BackupSummary[]>> {
      const result = await send('/v1/backups');
      if (result.status === 'failed') return result;

      try {
        const parsed = parseBackupList(await result.value.json());
        if (!parsed) return { status: 'failed', reason: 'malformed_response' };
        return { status: 'success', value: parsed };
      } catch {
        return { status: 'failed', reason: 'malformed_response' };
      }
    },

    /**
     * Fetches a snapshot's bytes, plus the schema version it was written with.
     *
     * The version travels with the bytes on purpose. Restoring a snapshot from
     * a newer build into an older one would hand the app a schema it cannot
     * migrate backwards out of, so the caller has to be able to refuse.
     */
    async downloadBackup(
      backupId: string = 'latest',
    ): Promise<SyncResult<{ bytes: Uint8Array; schemaVersion: number }>> {
      const result = await send(`/v1/backups/${backupId}`);
      if (result.status === 'failed') return result;

      try {
        const buffer = await result.value.arrayBuffer();
        const schemaVersion = Number(result.value.headers.get('x-snapshot-schema-version') ?? '0');
        return {
          status: 'success',
          value: { bytes: new Uint8Array(buffer), schemaVersion },
        };
      } catch {
        return { status: 'failed', reason: 'malformed_response' };
      }
    },
  };
}

export type SyncClient = ReturnType<typeof createSyncClient>;

function classifyStatus(status: number): SyncFailureReason {
  if (status === 401 || status === 403) return 'unauthorized';
  if (status === 404) return 'not_found';
  if (status === 413) return 'too_large';
  if (status === 422) return 'corrupted';
  if (status === 507) return 'quota_exceeded';
  return 'server_error';
}

function classifyError(error: unknown): SyncFailureReason {
  if (error instanceof Error) {
    if (error.name === 'AbortError') return 'timeout';
    if (/network|fetch failed|internet|unreachable/i.test(error.message)) return 'offline';
  }
  return 'server_error';
}
