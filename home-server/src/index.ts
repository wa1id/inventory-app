import { randomFillSync } from 'node:crypto';
import { join } from 'node:path';

import { serve } from '@hono/node-server';

import { configureRandomBytes } from '../../src/core/id.ts';
import { migrate } from '../../src/db/migrations.ts';
import { openNodeDatabase } from '../../src/db/nodeDatabase.ts';

import { createApp } from './app.ts';
import { DEFAULT_PORT } from './contract.ts';

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

  const dbPath = join(dataDir(), 'inventory.db');
  const db = openNodeDatabase(dbPath);
  const version = await migrate(db);

  const port = listenPort();
  const app = createApp();

  serve({ fetch: app.fetch, port, hostname: '0.0.0.0' }, (info) => {
    console.log(`inventory-api listening on ${info.address}:${info.port} (schema v${version})`);
  });
}

await start();
