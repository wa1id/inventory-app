import { randomFillSync } from 'node:crypto';
import { join } from 'node:path';

import { configureRandomBytes } from '../../src/core/id.ts';
import { openNodeDatabase } from '../../src/db/nodeDatabase.ts';

import { dbStoreFromEnv, runHouseholdBackup } from './backup.ts';
import { openControlStore } from './control.ts';

/**
 * One-shot upload of inventory.db + control.db. Used by `npm run backup:r2`
 * and as a compose exec while inventory-api is running (WAL allows it).
 */
configureRandomBytes((count) => randomFillSync(new Uint8Array(count)));

const dir = process.env.INVENTORY_DATA_DIR ?? './data';
const store = dbStoreFromEnv();
if (!store) {
  console.error('HOUSEHOLD_PHOTO_SECRET is required to upload a household DB snapshot.');
  process.exit(1);
}

const inventory = openNodeDatabase(join(dir, 'inventory.db'));
if (!inventory.snapshotAsync) {
  console.error('This SQLite adapter cannot snapshot.');
  process.exit(1);
}
const control = await openControlStore(join(dir, 'control.db'));

const result = await runHouseholdBackup({
  snapshotInventory: () => inventory.snapshotAsync!(),
  snapshotControl: () => control.snapshot(),
  store,
});
console.log(`uploaded ${result.id}`);
if (result.pruned.length > 0) {
  console.log(`pruned ${result.pruned.join(', ')}`);
}

await inventory.closeAsync();
await control.close();
