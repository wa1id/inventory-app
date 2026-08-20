import { randomFillSync } from 'node:crypto';
import { join } from 'node:path';

import { serve } from '@hono/node-server';

import { configureRandomBytes } from '../../src/core/id.ts';
import { migrate } from '../../src/db/migrations.ts';
import { openNodeDatabase } from '../../src/db/nodeDatabase.ts';
import { createRepositories } from '../../src/db/repositories.ts';

import { createApp } from './app.ts';
import { dbStoreFromEnv, startNightlyBackup } from './backup.ts';
import { DEFAULT_PORT } from './contract.ts';
import { openControlStore } from './control.ts';
import { createRevisionHub } from './hub.ts';
import { photoStoreFromEnv } from './photos.ts';

function dataDir(): string {
  return process.env.INVENTORY_DATA_DIR ?? './data';
}

function listenPort(): number {
  const raw = process.env.PORT;
  if (!raw) return DEFAULT_PORT;
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`PORT must be an integer 1–65535, got ${raw}`);
  }
  return port;
}

/**
 * Opens the household database, migrates it, then serves HTTP.
 *
 * The RNG is installed before any repository code can run. Schema v6 must be
 * applied before we accept traffic so a fresh volume is never left empty.
 */
export async function start(): Promise<void> {
  configureRandomBytes((count) => randomFillSync(new Uint8Array(count)));

  const dir = dataDir();
  const dbPath = join(dir, 'inventory.db');
  const db = openNodeDatabase(dbPath);
  const version = await migrate(db);

  const control = await openControlStore(join(dir, 'control.db'));
  if (control.bootstrapSecretToPrint) {
    // Printed once. Never written to disk, never uploaded to R2.
    console.log('Household bootstrap secret (save this; it cannot be recovered):');
    console.log(control.bootstrapSecretToPrint);
  }

  const publicOrigin = process.env.INVENTORY_PUBLIC_ORIGIN ?? 'https://inventory.wystudio.be';
  const photos = photoStoreFromEnv();
  if (!photos) {
    console.log(
      'HOUSEHOLD_PHOTO_SECRET not set; item photos will return 503 until the home server can call inventory-sync.',
    );
  }
  const webPassword = process.env.HOUSEHOLD_WEB_PASSWORD?.trim() || null;
  if (webPassword) {
    console.log('Household lookup page enabled at /');
  } else {
    console.log('HOUSEHOLD_WEB_PASSWORD not set; lookup page disabled.');
  }
  const port = listenPort();
  const app = createApp({
    control,
    publicOrigin,
    repos: createRepositories(db),
    hub: createRevisionHub(),
    photos,
    webPassword,
  });

  serve({ fetch: app.fetch, port, hostname: '0.0.0.0' }, (info) => {
    console.log(`inventory-api listening on ${info.address}:${info.port} (schema v${version})`);
  });

  startNightlyBackup({
    snapshotInventory: async () => {
      if (!db.snapshotAsync) throw new Error('inventory snapshot unavailable');
      return db.snapshotAsync();
    },
    snapshotControl: () => control.snapshot(),
    store: dbStoreFromEnv(),
  });
}

await start();
