import { mkdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { HOUSEHOLD_DB_FILES } from './contract.ts';
import type { DbBackupStore } from './backup.ts';

function unlinkIfPresent(path: string): void {
  try {
    unlinkSync(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
  }
}

/**
 * Writes inventory.db and control.db from a household snapshot.
 *
 * Never writes BOOTSTRAP.txt — the plaintext bootstrap secret is not stored
 * on disk or in R2. Stop inventory-api before restoring into the live volume.
 *
 * Throwaway check:
 *   INVENTORY_DATA_DIR=/tmp/inventory-restore npm run restore:r2
 */
export async function restoreHouseholdBackup(options: {
  store: DbBackupStore;
  dataDir: string;
  snapshotId?: string;
}): Promise<{ id: string; files: string[] }> {
  const listed = await options.store.list();
  const complete = listed.filter((row) =>
    HOUSEHOLD_DB_FILES.every((file) => row.files.includes(file)),
  );
  const target = options.snapshotId
    ? complete.find((row) => row.id === options.snapshotId)
    : complete[0];
  if (!target) {
    throw new Error(
      options.snapshotId
        ? `No complete snapshot ${options.snapshotId}.`
        : 'No complete household DB snapshot to restore.',
    );
  }

  mkdirSync(options.dataDir, { recursive: true });
  for (const file of HOUSEHOLD_DB_FILES) {
    const bytes = await options.store.get(target.id, file);
    if (!bytes) throw new Error(`Snapshot ${target.id} is missing ${file}`);
    const dest = join(options.dataDir, file);
    writeFileSync(dest, bytes);
    unlinkIfPresent(`${dest}-wal`);
    unlinkIfPresent(`${dest}-shm`);
  }
  return { id: target.id, files: [...HOUSEHOLD_DB_FILES] };
}
