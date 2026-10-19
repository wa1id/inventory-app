/**
 * Generates Fixtures/household/shadow-parity.json from the real src/services/household/shadow.ts
 * (`withLocalShadow`) running over node:sqlite (src/db/nodeDatabase.ts, the app's migrations).
 *
 * A script of household writes goes through the shadow decorator over a fake remote that answers
 * each write with the scripted server reply (or fails it). The local database starts with rows
 * the phone had before joining, so the ON CONFLICT branches, the visual_type reset, tag reuse
 * by lower-cased name, label replacement, cascades and the tombstone trigger all run. Every
 * step's outcome, whether `household_shadow_failed` was logged, and full dumps of the local
 * tables are recorded. ShadowParityTests replays the script through ShadowingRepositories (over
 * a stub home server answering the same replies) with the same clock and ids, and compares the
 * tables row for row.
 *
 * Mirrors that fail part-way are left out on purpose: shadow.ts runs a mirror's statements one
 * by one, the native mirror runs them in one transaction (04 §7), so a mid-graph failure leaves
 * different rows. ShadowingRepositoriesTests pins the native behaviour for that case.
 *
 * Not part of the RN test suite. To regenerate (see native-ios/docs/CONVENTIONS.md):
 *
 *   ln -s /home/walid/inventory-app/node_modules node_modules   # once, in a worktree
 *   mkdir -p src/__vectors__/__tests__
 *   cp native-ios/Packages/InventoryKit/Tests/InventoryServicesTests/Fixtures/household/generator/shadow-parity.test.ts \
 *      src/__vectors__/__tests__/
 *   npx jest src/__vectors__ --selectProjects logic
 *   rm -r src/__vectors__
 *
 * The JSON lands next to this folder, in Tests/InventoryServicesTests/Fixtures/household/.
 */
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { openNodeDatabase } from '@/db/nodeDatabase';
import { initializeRepositories, type Repositories } from '@/db/repositories';
import type { SqlDatabase } from '@/db/types';
import { withLocalShadow } from '@/services/household/shadow';
import { setTelemetrySink } from '@/services/telemetry';

// shadow.ts names new tags with newId(); a counter makes the ids reproducible in Swift.
let mockIdCount = 0;
jest.mock('@/core/id', () => ({
  ...jest.requireActual('@/core/id'),
  newId: () => `shadow-id-${++mockIdCount}`,
}));

const OUT = join(__dirname, '../../../native-ios/Packages/InventoryKit/Tests/InventoryServicesTests/Fixtures/household');

/** Shared with ShadowParityTests: Date.now() returns clockStart + n * clockStep on its n-th call. */
const SEEDS = { clockStart: 1_770_000_000_000, clockStep: 7, idPrefix: 'shadow-id-' };

const TOKEN_A = 'a'.repeat(32);
const TOKEN_B = 'b'.repeat(32);
const TOKEN_C = 'c'.repeat(32);

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

interface Step {
  op: string;
  sql?: string;
  id?: string;
  input?: Json;
  token?: string;
  containerId?: string;
  reply?: Json;
  remoteFails?: boolean;
}

function item(overrides: Record<string, Json>): Json {
  return {
    id: 'i1',
    containerId: 'c1',
    name: 'Drill',
    category: null,
    quantity: 1,
    notes: null,
    createdAt: 400,
    updatedAt: 400,
    photoId: null,
    photoUri: null,
    photoThumbUri: null,
    tags: [],
    spaceId: 's1',
    spaceName: 'Garage',
    spaceIcon: '🚗',
    spaceColor: '#5B8DEF',
    containerName: 'Shelf',
    containerShortCode: 'SHF-2222',
    ...overrides,
  };
}

const STEPS: Step[] = [
  // Seeded rows and the tombstone trigger use SQLite's wall clock.
  { op: 'sql', sql: "UPDATE spaces SET created_at = 0, updated_at = 0 WHERE kind = 'system'" },
  { op: 'sql', sql: "UPDATE containers SET created_at = 0, updated_at = 0 WHERE kind = 'system'" },
  // What the phone held before it joined.
  { op: 'sql', sql: "INSERT INTO spaces (id, name, icon, color, created_at, updated_at) VALUES ('local-space', 'Attic', '📦', '#E4572E', 1, 1)" },
  { op: 'sql', sql: "INSERT INTO containers (id, space_id, name, visual_type, short_code, created_at, updated_at) VALUES ('local-box', 'local-space', 'Old box', 'drawer', 'BOX-AAAA', 2, 2)" },
  { op: 'sql', sql: "INSERT INTO items (id, container_id, name, category, quantity, notes, created_at, updated_at, search_text) VALUES ('local-item', 'local-box', 'Lamp', NULL, 1, NULL, 3, 3, 'lamp')" },
  { op: 'sql', sql: "INSERT INTO tags (id, name, normalized_name, created_at) VALUES ('tag-power', 'Power', 'power', 4), ('tag-cafe', 'Café', 'cafe', 4)" },
  { op: 'sql', sql: `INSERT INTO qr_bindings (id, token, container_id, created_at, updated_at) VALUES ('local-qr', '${TOKEN_A}', 'local-box', 5, 5)` },
  { op: 'dump' },

  // Spaces: an insert, updates (created_at is never overwritten), one that is not local yet,
  // one the server no longer has, and a failed write.
  { op: 'spaces.create', input: { name: 'Garage', icon: '🚗', color: '#5B8DEF' }, reply: { id: 's1', name: 'Garage', icon: '🚗', color: '#5B8DEF', createdAt: 100, updatedAt: 100 } },
  { op: 'spaces.update', id: 's1', input: { name: ' Garage 2 ' }, reply: { id: 's1', name: ' Garage 2 ', icon: '🚗', color: '#5B8DEF', createdAt: 150, updatedAt: 200 } },
  { op: 'spaces.update', id: 'local-space', input: { icon: '🏠' }, reply: { id: 'local-space', name: 'Attic', icon: '🏠', color: '#E4572E', createdAt: 999, updatedAt: 210 } },
  { op: 'spaces.update', id: 'remote-space', input: { name: 'Shed' }, reply: { id: 'remote-space', name: 'Shed', icon: '', color: '', createdAt: 220, updatedAt: 220 } },
  { op: 'spaces.update', id: 'gone', input: { name: 'x' }, reply: null },
  { op: 'spaces.create', input: { name: 'Nope', icon: '', color: '' }, remoteFails: true },

  // Containers: an insert, an update (short code and look replaced), a short code another local
  // container holds and a space this phone never saw (both refused locally), a move with a look
  // this build does not know, and one the server no longer has.
  { op: 'containers.create', input: { spaceId: 's1', visualType: 'box' }, reply: { id: 'c1', spaceId: 's1', name: null, visualType: 'box', shortCode: 'BOX-1111', createdAt: 300, updatedAt: 300 } },
  { op: 'containers.update', id: 'c1', input: { name: 'Shelf', visualType: 'shelf' }, reply: { id: 'c1', spaceId: 's1', name: 'Shelf', visualType: 'shelf', shortCode: 'SHF-2222', createdAt: 999, updatedAt: 310 } },
  { op: 'containers.create', input: { spaceId: 's1', visualType: 'box', name: 'Clash' }, reply: { id: 'c-clash', spaceId: 's1', name: 'Clash', visualType: 'box', shortCode: 'BOX-AAAA', createdAt: 320, updatedAt: 320 } },
  { op: 'containers.create', input: { spaceId: 'elsewhere', visualType: 'bin' }, reply: { id: 'c-orphan', spaceId: 'elsewhere', name: null, visualType: 'bin', shortCode: 'BIN-3333', createdAt: 330, updatedAt: 330 } },
  { op: 'containers.update', id: 'local-box', input: { spaceId: 's1' }, reply: { id: 'local-box', spaceId: 's1', name: 'Old box', visualType: 'Trunk', shortCode: 'BOX-AAAA', createdAt: 2, updatedAt: 340 } },
  { op: 'containers.update', id: 'gone', input: { name: null }, reply: null },
  { op: 'dump' },

  // Items: the whole graph with a photo and tags (reused by lower-cased name, JS case rules),
  // the drop zone (its look reset to box, an empty short code replaced), a graph into places
  // this phone never saw, a photo id seen before, row-only updates, a move the local database
  // refuses, one the server no longer has, and a conflict.
  {
    op: 'items.create',
    input: { containerId: 'c1', name: 'Drill' },
    reply: item({
      name: '  Cordless Drill ',
      category: ' Power Tools ',
      quantity: 2,
      notes: 'Charger',
      photoId: 'p1',
      photoUri: 'r2:household/primary/photos/p1.webp',
      photoThumbUri: 'r2:household/primary/photos/p1-thumb.webp',
      tags: ['  Power ', 'POWER', 'Café', '', '   ', 'İstanbul', 'ΣΑΣ', 'power'],
    }),
  },
  {
    op: 'items.create',
    input: { containerId: 'drop-zone' },
    reply: item({
      id: 'i2', containerId: 'drop-zone', name: '', createdAt: 410, updatedAt: 411,
      spaceId: 'drop-zone-space', spaceName: 'Drop zone', spaceIcon: '📥', spaceColor: '#0F9BB0',
      containerName: null, containerShortCode: '', tags: ['Power'],
    }),
  },
  {
    op: 'items.create',
    input: { containerId: 'remote-box', name: 'Saw' },
    reply: item({
      id: 'i3', containerId: 'remote-box', name: 'Saw', category: 'ΟΔΟΣ', createdAt: 412, updatedAt: 412,
      spaceId: 'far-space', spaceName: 'Workshop', spaceIcon: '🔧', spaceColor: '#123456',
      containerName: 'Rack', containerShortCode: 'RCK-4444', photoId: 'p3', photoUri: null,
    }),
  },
  {
    op: 'items.create',
    input: { containerId: 'c1', name: 'Bits' },
    reply: item({
      id: 'i4', name: 'Bits', createdAt: 413, updatedAt: 413,
      photoId: 'p1', photoUri: 'r2:household/primary/photos/p1-again.webp', photoThumbUri: null,
    }),
  },
  { op: 'items.update', id: 'i1', input: { name: 'Cordless ΟΔΟΣ', quantity: 0 }, reply: { id: 'i1', containerId: 'c1', name: '  Cordless ΟΔΟΣ ', category: null, quantity: 0, notes: 'n', createdAt: 999, updatedAt: 420 } },
  { op: 'items.update', id: 'local-item', input: { containerId: 'c1' }, reply: { id: 'local-item', containerId: 'c1', name: 'Lamp', category: 'Light', quantity: 1, notes: null, createdAt: 3, updatedAt: 430 } },
  { op: 'items.update', id: 'i1', input: { containerId: 'elsewhere' }, reply: { id: 'i1', containerId: 'elsewhere', name: 'x', category: null, quantity: 1, notes: null, createdAt: 400, updatedAt: 440 } },
  { op: 'items.update', id: 'gone', input: { quantity: 3 }, reply: null },
  { op: 'items.update', id: 'i1', input: { name: 'Late', expectedUpdatedAt: 1 }, remoteFails: true },
  { op: 'dump' },

  // Labels: a new label, a printed one moved here (it replaces the label on its token and the
  // one on this container), an unbind of nothing, and an unbind.
  { op: 'qr.createAndBind', containerId: 'c1', reply: { id: 'q1', token: TOKEN_B, containerId: 'c1', createdAt: 500, updatedAt: 500 } },
  { op: 'qr.bind', token: TOKEN_A, containerId: 'c1', reply: { id: 'q2', token: TOKEN_A, containerId: 'c1', createdAt: 510, updatedAt: 510 } },
  { op: 'qr.unbind', containerId: 'local-box', reply: false },
  { op: 'qr.createAndBind', containerId: 'local-box', reply: { id: 'q3', token: TOKEN_C, containerId: 'local-box', createdAt: 520, updatedAt: 520 } },
  { op: 'qr.unbind', containerId: 'c1', reply: true },
  { op: 'dump' },

  // Deletes: only what the server deleted, cascading locally (and tombstoning a synced photo).
  { op: 'items.delete', id: 'i1', reply: { deleted: true, orphanedPhotoUris: ['r2:household/primary/photos/p1-again.webp'] } },
  { op: 'items.delete', id: 'gone', reply: { deleted: false, orphanedPhotoUris: [] } },
  { op: 'containers.delete', id: 'local-box', reply: { deleted: true, orphanedPhotoUris: [] } },
  { op: 'containers.delete', id: 'drop-zone', remoteFails: true },
  { op: 'spaces.delete', id: 's1', reply: { deleted: true, orphanedPhotoUris: [] } },
  { op: 'spaces.delete', id: 'gone', reply: { deleted: false, orphanedPhotoUris: [] } },
  { op: 'sql', sql: 'UPDATE sync_deletions SET deleted_at = 0' },
  { op: 'dump' },
];

const TABLES = ['spaces', 'containers', 'items', 'item_photos', 'tags', 'item_tags', 'qr_bindings', 'sync_deletions'];

async function dumpTables(db: SqlDatabase): Promise<Record<string, unknown[]>> {
  const out: Record<string, unknown[]> = {};
  for (const table of TABLES) {
    out[table] = await db.getAllAsync(`SELECT * FROM ${table} ORDER BY rowid`);
  }
  return out;
}

/** A remote whose writes answer the scripted reply of the step being run. */
function scriptedRemote(current: () => Step): Repositories {
  const answer = async () => {
    const step = current();
    if (step.remoteFails) throw new Error('boom');
    return step.reply as never;
  };
  const unused = async () => {
    throw new Error('not scripted');
  };
  return {
    db: undefined as never,
    spaces: { listWithCounts: unused, getById: unused, deletionImpact: unused, create: answer, update: answer, delete: answer },
    containers: {
      listBySpace: unused, getById: unused, getWithCounts: unused, deletionImpact: unused, listAllWithSpace: unused,
      create: answer, update: answer, delete: answer,
    },
    items: {
      listByContainer: unused, listUnsorted: unused, listRecent: unused, countUnsorted: unused, getById: unused,
      getPhotos: unused, countAll: unused, create: answer, update: answer, delete: answer,
    },
    qr: { resolveScan: unused, getByContainer: unused, getByToken: unused, bind: answer, createAndBind: answer, unbind: answer },
    search: { search: unused, searchSpaces: unused, searchContainers: unused },
  } as unknown as Repositories;
}

async function run(repos: Repositories, step: Step): Promise<unknown> {
  const input = step.input as never;
  const id = step.id as string;
  switch (step.op) {
    case 'spaces.create': return repos.spaces.create(input);
    case 'spaces.update': return repos.spaces.update(id, input);
    case 'spaces.delete': return repos.spaces.delete(id);
    case 'containers.create': return repos.containers.create(input);
    case 'containers.update': return repos.containers.update(id, input);
    case 'containers.delete': return repos.containers.delete(id);
    case 'items.create': return repos.items.create(input);
    case 'items.update': return repos.items.update(id, input);
    case 'items.delete': return repos.items.delete(id);
    case 'qr.bind': return repos.qr.bind(step.token as string, step.containerId as string);
    case 'qr.createAndBind': return repos.qr.createAndBind(step.containerId as string);
    case 'qr.unbind': return repos.qr.unbind(step.containerId as string);
    default: throw new Error(`unknown op ${step.op}`);
  }
}

describe('household shadow parity', () => {
  it('writes the shadow script and the local tables shadow.ts left', async () => {
    const db = openNodeDatabase();
    const local = await initializeRepositories(db);
    let currentStep: Step = STEPS[0]!;
    const shadowed = withLocalShadow(scriptedRemote(() => currentStep), local);

    const events: string[] = [];
    setTelemetrySink({ event: (name) => events.push(name), error: (name) => events.push(`error:${name}`) });

    // Only the shadow's own calls advance the clock from here on.
    let clock = SEEDS.clockStart;
    const now = jest.spyOn(Date, 'now').mockImplementation(() => {
      clock += SEEDS.clockStep;
      return clock;
    });

    try {
      const out: Record<string, unknown>[] = [];
      for (const step of STEPS) {
        currentStep = step;
        if (step.op === 'sql') {
          await db.execAsync(step.sql as string);
          out.push({ ...step });
          continue;
        }
        if (step.op === 'dump') {
          out.push({ ...step, tables: await dumpTables(db) });
          continue;
        }
        events.length = 0;
        let outcome: 'ok' | 'error';
        try {
          await run(shadowed, step);
          outcome = 'ok';
        } catch {
          outcome = 'error';
        }
        out.push({ ...step, outcome, shadowFailed: events.includes('household_shadow_failed'), events: [...events] });
      }
      writeFileSync(join(OUT, 'shadow-parity.json'), `${JSON.stringify({ seeds: SEEDS, steps: out }, null, 1)}\n`);
    } finally {
      now.mockRestore();
      await db.closeAsync();
    }
  });
});
