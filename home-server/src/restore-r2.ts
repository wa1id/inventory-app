import { dbStoreFromEnv } from './backup.ts';
import { restoreHouseholdBackup } from './restore.ts';

/**
 * Downloads the latest (or named) household DB snapshot into INVENTORY_DATA_DIR.
 *
 * Stop inventory-api before restoring the live volume. For a throwaway check:
 *   INVENTORY_DATA_DIR=/tmp/inventory-restore npm run restore:r2
 *
 * Optional snapshot id: `npm run restore:r2 -- 2026-08-21T01-00-00Z`
 */
const dir = process.env.INVENTORY_DATA_DIR ?? './data';
const store = dbStoreFromEnv();
if (!store) {
  console.error('HOUSEHOLD_PHOTO_SECRET is required to restore a household DB snapshot.');
  process.exit(1);
}

const snapshotId = process.argv[2];
const result = await restoreHouseholdBackup({
  store,
  dataDir: dir,
  snapshotId,
});
console.log(`restored ${result.id} -> ${dir} (${result.files.join(', ')})`);
