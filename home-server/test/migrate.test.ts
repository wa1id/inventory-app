import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { LATEST_SCHEMA_VERSION, migrate } from '../../src/db/migrations.ts';
import { openNodeDatabase } from '../../src/db/nodeDatabase.ts';

test('migrates a new file database to schema v6', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'inventory-home-'));
  try {
    const db = openNodeDatabase(join(dir, 'inventory.db'));
    const version = await migrate(db);
    assert.equal(version, LATEST_SCHEMA_VERSION);
    assert.equal(LATEST_SCHEMA_VERSION, 6);

    const row = await db.getFirstAsync<{ user_version: number }>('PRAGMA user_version');
    assert.equal(row?.user_version, 6);

    await db.closeAsync();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a second migrate on the same file is a no-op', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'inventory-home-'));
  try {
    const path = join(dir, 'inventory.db');
    const first = openNodeDatabase(path);
    await migrate(first);
    await first.closeAsync();

    const second = openNodeDatabase(path);
    assert.equal(await migrate(second), 6);
    await second.closeAsync();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
