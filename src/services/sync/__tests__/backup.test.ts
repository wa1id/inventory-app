import { LATEST_SCHEMA_VERSION, MIGRATIONS, migrate } from '@/db/migrations';
import { createRepositories } from '@/db/repositories';
import { openNodeDatabase } from '@/db/testing/nodeDatabase';
import type { SqlDatabase } from '@/db/types';
import {
  MIN_BACKUP_INTERVAL_MS,
  maybeBackup,
  readSchemaVersion,
  restoreBackup,
  runBackup,
} from '@/services/sync/backup';
import type { SyncClient } from '@/services/sync/client';
import { MAX_BACKUP_BYTES, type SyncFailureReason } from '@/services/sync/contract';

const mockPreferences = new Map<string, string>();

jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: async (key: string) => mockPreferences.get(key) ?? null,
    setItem: async (key: string, value: string) => {
      mockPreferences.set(key, value);
    },
    removeItem: async (key: string) => {
      mockPreferences.delete(key);
    },
  },
}));

/**
 * A snapshot that is a real SQL dump, replayed on restore.
 *
 * Faithful enough to matter: restoring genuinely replaces the database's
 * contents, so the "snapshot from an older build gets migrated forward" test is
 * exercising the real migration path rather than asserting against a stub.
 */
function withSnapshotting(db: SqlDatabase): SqlDatabase {
  return Object.assign(db, {
    async snapshotAsync(): Promise<Uint8Array> {
      const tables = await db.getAllAsync<{ name: string; sql: string }>(
        `SELECT name, sql FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`,
      );
      const version = await readSchemaVersion(db);
      const statements: string[] = [`PRAGMA user_version = ${version};`];

      for (const table of tables) {
        statements.push(`${table.sql};`);
        const rows = await db.getAllAsync<Record<string, unknown>>(`SELECT * FROM "${table.name}"`);
        for (const row of rows) {
          const columns = Object.keys(row);
          const values = columns.map((column) => literal(row[column]));
          statements.push(
            `INSERT INTO "${table.name}" (${columns.map((c) => `"${c}"`).join(',')}) VALUES (${values.join(',')});`,
          );
        }
      }

      return new TextEncoder().encode(statements.join('\n'));
    },

    async restoreAsync(snapshot: Uint8Array): Promise<void> {
      const existing = await db.getAllAsync<{ name: string }>(
        `SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`,
      );
      await db.execAsync('PRAGMA foreign_keys = OFF');
      for (const table of existing) {
        await db.execAsync(`DROP TABLE IF EXISTS "${table.name}"`);
      }
      await db.execAsync(new TextDecoder().decode(snapshot));
      await db.execAsync('PRAGMA foreign_keys = ON');
    },
  });
}

function literal(value: unknown): string {
  if (value === null || value === undefined) return 'NULL';
  if (typeof value === 'number') return String(value);
  return `'${String(value).replace(/'/g, "''")}'`;
}

interface FakeClient extends SyncClient {
  stored: { bytes: Uint8Array; schemaVersion: number; checksum?: string }[];
}

function fakeClient(
  options: { failWith?: SyncFailureReason; schemaVersion?: number } = {},
): FakeClient {
  const stored: { bytes: Uint8Array; schemaVersion: number; checksum?: string }[] = [];
  let counter = 0;

  return {
    configured: true,
    stored,

    async uploadBackup(bytes: Uint8Array, schemaVersion: number, checksum?: string) {
      if (options.failWith) return { status: 'failed', reason: options.failWith };
      stored.push({ bytes, schemaVersion, checksum });
      counter += 1;
      return {
        status: 'success',
        value: {
          id: String(counter),
          size: bytes.byteLength,
          capturedAt: 1_000 * counter,
          schemaVersion,
        },
      };
    },

    async downloadBackup() {
      if (options.failWith) return { status: 'failed', reason: options.failWith };
      const newest = stored[stored.length - 1];
      if (!newest) return { status: 'failed', reason: 'not_found' };
      return {
        status: 'success',
        value: {
          bytes: newest.bytes,
          schemaVersion: options.schemaVersion ?? newest.schemaVersion,
        },
      };
    },
  } as unknown as FakeClient;
}

async function seededDb(): Promise<SqlDatabase> {
  const db = withSnapshotting(openNodeDatabase());
  await migrate(db);
  const repos = createRepositories(db);
  const space = await repos.spaces.create({ name: 'Garage', icon: 'car', color: '#5B8DEF' });
  const container = await repos.containers.create({ spaceId: space.id, visualType: 'box' });
  await repos.items.create({ containerId: container.id, name: 'Cordless Drill', quantity: 1 });
  return db;
}

beforeEach(() => {
  mockPreferences.clear();
});

describe('runBackup', () => {
  it('uploads a snapshot tagged with the current schema version', async () => {
    const db = await seededDb();
    const client = fakeClient();

    const result = await runBackup(db, client);

    expect(result.status).toBe('success');
    expect(client.stored).toHaveLength(1);
    expect(client.stored[0]?.schemaVersion).toBe(LATEST_SCHEMA_VERSION);
  });

  it('sends a checksum so the service can reject a corrupted upload', async () => {
    const db = await seededDb();
    const client = fakeClient();

    await runBackup(db, client);

    expect(client.stored[0]?.checksum).toMatch(/^[0-9a-f]{64}$/);
  });

  it('reports failure without recording a backup time', async () => {
    const db = await seededDb();

    const result = await runBackup(db, fakeClient({ failWith: 'offline' }));

    expect(result).toEqual({ status: 'failed', reason: 'offline' });
    expect(mockPreferences.size).toBe(0);
  });

  it('degrades cleanly on a backend that cannot snapshot itself', async () => {
    const db = openNodeDatabase();
    await migrate(db);
    delete db.snapshotAsync;

    await expect(runBackup(db, fakeClient())).resolves.toEqual({
      status: 'failed',
      reason: 'not_configured',
    });
  });

  it('refuses a snapshot larger than the service accepts', async () => {
    const db = await seededDb();
    // Refusing locally avoids pushing tens of megabytes over a metered
    // connection just to be rejected at the other end.
    db.snapshotAsync = async () => new Uint8Array(MAX_BACKUP_BYTES + 1);

    await expect(runBackup(db, fakeClient())).resolves.toEqual({
      status: 'failed',
      reason: 'too_large',
    });
  });
});

describe('maybeBackup', () => {
  it('backs up when nothing has been backed up yet', async () => {
    const db = await seededDb();
    const client = fakeClient();

    expect(await maybeBackup(db, client)).not.toBeNull();
    expect(client.stored).toHaveLength(1);
  });

  it('skips a backup taken too recently', async () => {
    const db = await seededDb();
    const client = fakeClient();

    await runBackup(db, client);
    const skipped = await maybeBackup(db, client, 1_000 + MIN_BACKUP_INTERVAL_MS - 1);

    expect(skipped).toBeNull();
    expect(client.stored).toHaveLength(1);
  });

  it('backs up again once the interval has passed', async () => {
    const db = await seededDb();
    const client = fakeClient();

    await runBackup(db, client);
    await maybeBackup(db, client, 1_000 + MIN_BACKUP_INTERVAL_MS + 1);

    expect(client.stored).toHaveLength(2);
  });
});

describe('restoreBackup', () => {
  it('brings back data that was deleted after the snapshot', async () => {
    const db = await seededDb();
    const client = fakeClient();
    await runBackup(db, client);

    await db.execAsync('DELETE FROM items');
    expect(await db.getAllAsync('SELECT id FROM items')).toEqual([]);

    const result = await restoreBackup(db, client);

    expect(result.status).toBe('success');
    const items = await db.getAllAsync<{ name: string }>('SELECT name FROM items');
    expect(items).toEqual([{ name: 'Cordless Drill' }]);
  });

  it('migrates a snapshot from an older build forward', async () => {
    // A database that only ever saw migration 1, snapshotted by an old build.
    const old = withSnapshotting(openNodeDatabase());
    const [first] = MIGRATIONS;
    await migrate(old, first ? [first] : []);

    const client = fakeClient();
    await runBackup(old, client);
    expect(client.stored[0]?.schemaVersion).toBe(1);

    const db = await seededDb();
    const result = await restoreBackup(db, client);

    expect(result.status).toBe('success');
    // Restored at v1, then carried forward — otherwise the app would be holding
    // a schema its own queries no longer match.
    await expect(readSchemaVersion(db)).resolves.toBe(LATEST_SCHEMA_VERSION);
  });

  it('refuses a snapshot written by a newer build', async () => {
    const db = await seededDb();
    const client = fakeClient({ schemaVersion: LATEST_SCHEMA_VERSION + 1 });
    await runBackup(db, client);

    const result = await restoreBackup(db, client);

    // Migrations only run forwards; accepting this would surface later as
    // corruption instead of here as a refusal.
    expect(result).toEqual({ status: 'failed', reason: 'corrupted' });
  });

  it('passes through a download failure without touching local data', async () => {
    const db = await seededDb();

    const result = await restoreBackup(db, fakeClient({ failWith: 'offline' }));

    expect(result).toEqual({ status: 'failed', reason: 'offline' });
    const items = await db.getAllAsync<{ name: string }>('SELECT name FROM items');
    expect(items).toEqual([{ name: 'Cordless Drill' }]);
  });
});
