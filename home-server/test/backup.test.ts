import assert from 'node:assert/strict';
import { randomFillSync } from 'node:crypto';
import { mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { configureRandomBytes } from '../../src/core/id.ts';
import { initializeRepositories } from '../../src/db/repositories.ts';
import { openNodeDatabase } from '../../src/db/nodeDatabase.ts';

import {
  brusselsHour,
  createMemoryDbStore,
  formatSnapshotId,
  runHouseholdBackup,
  shouldRunBackup,
} from '../src/backup.ts';
import { openControlStore } from '../src/control.ts';
import { restoreHouseholdBackup } from '../src/restore.ts';

configureRandomBytes((count) => randomFillSync(new Uint8Array(count)));

test('03:00 Europe/Brussels is the backup window, once per local date', () => {
  const summerThree = new Date('2026-08-21T01:00:00Z');
  assert.equal(brusselsHour(summerThree), 3);
  const first = shouldRunBackup(summerThree, null);
  assert.equal(first.run, true);
  assert.equal(first.date, '2026-08-21');
  assert.equal(shouldRunBackup(summerThree, first.date).run, false);
  assert.equal(shouldRunBackup(new Date('2026-08-21T12:00:00Z'), null).run, false);
});

test('runHouseholdBackup uploads both DBs, prunes extras, and never writes BOOTSTRAP.txt', async () => {
  const store = createMemoryDbStore();
  const inventory = new Uint8Array([1, 2, 3]);
  const control = new Uint8Array([4, 5]);

  for (let hour = 0; hour < 8; hour += 1) {
    await runHouseholdBackup({
      snapshotInventory: async () => inventory,
      snapshotControl: async () => control,
      store,
      now: new Date(Date.UTC(2026, 7, 21, hour, 0, 0)),
      retention: 7,
    });
  }

  const listed = await store.list();
  assert.equal(listed.length, 7);
  assert.ok(listed.every((row) => row.files.includes('inventory.db')));
  assert.ok(listed.every((row) => row.files.includes('control.db')));
  assert.ok(listed.every((row) => !row.files.includes('BOOTSTRAP.txt')));
});

test('restoreHouseholdBackup writes only the two SQLite files into a throwaway dir', async () => {
  const sourceDir = mkdtempSync(join(tmpdir(), 'inventory-backup-src-'));
  const restoreDir = mkdtempSync(join(tmpdir(), 'inventory-backup-dst-'));
  const store = createMemoryDbStore();

  try {
    const repos = await initializeRepositories(openNodeDatabase(join(sourceDir, 'inventory.db')));
    const space = await repos.spaces.create({ name: 'Garage', icon: '🚗', color: '#5B8DEF' });
    const control = await openControlStore(join(sourceDir, 'control.db'));
    if (!repos.db.snapshotAsync) throw new Error('expected snapshotAsync');

    const uploaded = await runHouseholdBackup({
      snapshotInventory: () => repos.db.snapshotAsync!(),
      snapshotControl: () => control.snapshot(),
      store,
      now: new Date('2026-08-21T01:00:00Z'),
    });
    assert.equal(uploaded.id, formatSnapshotId(new Date('2026-08-21T01:00:00Z')));

    const restored = await restoreHouseholdBackup({ store, dataDir: restoreDir });
    assert.equal(restored.id, uploaded.id);
    assert.deepEqual(readdirSync(restoreDir).sort(), ['control.db', 'inventory.db']);

    const restoredRepos = await initializeRepositories(
      openNodeDatabase(join(restoreDir, 'inventory.db')),
    );
    const restoredSpace = await restoredRepos.spaces.getById(space.id);
    assert.equal(restoredSpace?.name, 'Garage');

    const restoredControl = await openControlStore(join(restoreDir, 'control.db'));
    const devices = await restoredControl.listDevices();
    assert.equal(devices.length, 0);

    await control.close();
    await restoredControl.close();
    await repos.db.closeAsync();
    await restoredRepos.db.closeAsync();
  } finally {
    rmSync(sourceDir, { recursive: true, force: true });
    rmSync(restoreDir, { recursive: true, force: true });
  }
});
