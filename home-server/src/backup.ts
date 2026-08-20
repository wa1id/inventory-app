import {
  BACKUP_HOUR,
  BACKUP_TZ,
  DEFAULT_PHOTO_WORKER_ORIGIN,
  HOUSEHOLD_DB_FILES,
  HOUSEHOLD_DB_RETENTION,
  type HouseholdDbFile,
} from './contract.ts';

export interface SnapshotInfo {
  id: string;
  files: string[];
  bytes: number;
}

export interface DbBackupStore {
  put(snapshotId: string, file: HouseholdDbFile, bytes: Uint8Array): Promise<void>;
  get(snapshotId: string, file: HouseholdDbFile): Promise<Uint8Array | null>;
  list(): Promise<SnapshotInfo[]>;
  remove(snapshotId: string): Promise<void>;
}

export function formatSnapshotId(at: Date): string {
  return at
    .toISOString()
    .replace(/\.\d{3}Z$/, 'Z')
    .replaceAll(':', '-');
}

export function brusselsDate(at: Date, timeZone = BACKUP_TZ): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(at);
}

export function brusselsHour(at: Date, timeZone = BACKUP_TZ): number {
  const hour = new Intl.DateTimeFormat('en-GB', {
    timeZone,
    hour: '2-digit',
    hourCycle: 'h23',
  })
    .formatToParts(at)
    .find((part) => part.type === 'hour')?.value;
  return Number(hour);
}

export function shouldRunBackup(
  at: Date,
  lastRunDate: string | null,
  hour = BACKUP_HOUR,
  timeZone = BACKUP_TZ,
): { run: boolean; date: string } {
  const date = brusselsDate(at, timeZone);
  if (brusselsHour(at, timeZone) !== hour) return { run: false, date };
  if (lastRunDate === date) return { run: false, date };
  return { run: true, date };
}

export function createMemoryDbStore(): DbBackupStore {
  const objects = new Map<string, Uint8Array>();

  function prefix(snapshotId: string): string {
    return `${snapshotId}/`;
  }

  return {
    async put(snapshotId, file, bytes) {
      objects.set(`${snapshotId}/${file}`, new Uint8Array(bytes));
    },
    async get(snapshotId, file) {
      const stored = objects.get(`${snapshotId}/${file}`);
      return stored ? new Uint8Array(stored) : null;
    },
    async list() {
      const grouped = new Map<string, SnapshotInfo>();
      for (const [key, bytes] of objects) {
        const slash = key.indexOf('/');
        if (slash <= 0) continue;
        const id = key.slice(0, slash);
        const file = key.slice(slash + 1);
        const current = grouped.get(id) ?? { id, files: [], bytes: 0 };
        current.files.push(file);
        current.bytes += bytes.byteLength;
        grouped.set(id, current);
      }
      return [...grouped.values()]
        .map((row) => ({ ...row, files: row.files.sort() }))
        .sort((a, b) => (a.id < b.id ? 1 : a.id > b.id ? -1 : 0));
    },
    async remove(snapshotId) {
      const start = prefix(snapshotId);
      for (const key of [...objects.keys()]) {
        if (key.startsWith(start)) objects.delete(key);
      }
    },
  };
}

/**
 * Talks to inventory-sync `/v1/household/db/*` with the same Worker secret
 * as household photos. No R2 S3 token on the box.
 */
export function createWorkerDbStore(env: {
  origin: string;
  secret: string;
  fetch?: typeof fetch;
}): DbBackupStore {
  const origin = env.origin.replace(/\/+$/, '');
  const fetchImpl = env.fetch ?? fetch;
  const authorization = `Bearer ${env.secret}`;

  return {
    async put(snapshotId, file, bytes) {
      const response = await fetchImpl(
        `${origin}/v1/household/db/${encodeURIComponent(snapshotId)}/${file}`,
        {
          method: 'PUT',
          headers: {
            authorization,
            'content-type': 'application/vnd.sqlite3',
          },
          body: Buffer.from(bytes),
        },
      );
      if (!response.ok) throw new Error(`DB backup put failed (${response.status})`);
    },
    async get(snapshotId, file) {
      const response = await fetchImpl(
        `${origin}/v1/household/db/${encodeURIComponent(snapshotId)}/${file}`,
        { headers: { authorization } },
      );
      if (response.status === 404) return null;
      if (!response.ok) throw new Error(`DB backup get failed (${response.status})`);
      return new Uint8Array(await response.arrayBuffer());
    },
    async list() {
      const response = await fetchImpl(`${origin}/v1/household/db`, {
        headers: { authorization },
      });
      if (!response.ok) throw new Error(`DB backup list failed (${response.status})`);
      const body = (await response.json()) as { snapshots?: SnapshotInfo[] };
      return Array.isArray(body.snapshots) ? body.snapshots : [];
    },
    async remove(snapshotId) {
      const response = await fetchImpl(
        `${origin}/v1/household/db/${encodeURIComponent(snapshotId)}`,
        { method: 'DELETE', headers: { authorization } },
      );
      if (!response.ok && response.status !== 404) {
        throw new Error(`DB backup delete failed (${response.status})`);
      }
    },
  };
}

export function dbStoreFromEnv(env: NodeJS.ProcessEnv = process.env): DbBackupStore | null {
  const secret = env.HOUSEHOLD_PHOTO_SECRET?.trim();
  if (!secret) return null;
  return createWorkerDbStore({
    origin: env.HOUSEHOLD_PHOTO_ORIGIN?.trim() || DEFAULT_PHOTO_WORKER_ORIGIN,
    secret,
  });
}

export async function runHouseholdBackup(options: {
  snapshotInventory: () => Promise<Uint8Array>;
  snapshotControl: () => Promise<Uint8Array>;
  store: DbBackupStore;
  now?: Date;
  retention?: number;
}): Promise<{ id: string; pruned: string[] }> {
  const id = formatSnapshotId(options.now ?? new Date());
  await options.store.put(id, 'inventory.db', await options.snapshotInventory());
  await options.store.put(id, 'control.db', await options.snapshotControl());

  const keep = options.retention ?? HOUSEHOLD_DB_RETENTION;
  const listed = await options.store.list();
  const complete = listed.filter((row) =>
    HOUSEHOLD_DB_FILES.every((file) => row.files.includes(file)),
  );
  const keepIds = new Set(complete.slice(0, keep).map((row) => row.id));
  const pruned: string[] = [];
  for (const row of listed) {
    if (keepIds.has(row.id)) continue;
    await options.store.remove(row.id);
    pruned.push(row.id);
  }
  return { id, pruned };
}

export function startNightlyBackup(options: {
  snapshotInventory: () => Promise<Uint8Array>;
  snapshotControl: () => Promise<Uint8Array>;
  store: DbBackupStore | null;
  intervalMs?: number;
  log?: (message: string) => void;
}): () => void {
  const log = options.log ?? console.log;
  if (!options.store) {
    log('HOUSEHOLD_PHOTO_SECRET not set; nightly DB backup is disabled.');
    return () => {};
  }

  let lastRunDate: string | null = null;
  let inFlight = false;

  async function tick(): Promise<void> {
    const decision = shouldRunBackup(new Date(), lastRunDate);
    if (!decision.run || inFlight || !options.store) return;
    inFlight = true;
    lastRunDate = decision.date;
    try {
      const result = await runHouseholdBackup({
        snapshotInventory: options.snapshotInventory,
        snapshotControl: options.snapshotControl,
        store: options.store,
      });
      log(`household db backup ${result.id} uploaded`);
    } catch (error) {
      lastRunDate = null;
      log(`household db backup failed: ${error instanceof Error ? error.name : 'unknown'}`);
    } finally {
      inFlight = false;
    }
  }

  const timer = setInterval(() => {
    void tick();
  }, options.intervalMs ?? 60_000);
  return () => clearInterval(timer);
}
