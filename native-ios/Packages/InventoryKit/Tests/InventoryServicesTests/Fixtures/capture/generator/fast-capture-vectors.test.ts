/**
 * Generates the Quick Snap pipeline and review-session parity vectors from the real TypeScript:
 * src/services/capture/fastCapture.ts (`captureFastItem` against recording fakes) and
 * src/services/capture/fastReview.ts (`sessionItems`, `summarizeSession`).
 *
 * Not part of the RN test suite. To regenerate (see native-ios/docs/CONVENTIONS.md):
 *
 *   ln -s /home/walid/inventory-app/node_modules node_modules   # once, in a worktree
 *   mkdir -p src/__vectors__/__tests__
 *   cp native-ios/Packages/InventoryKit/Tests/InventoryServicesTests/Fixtures/capture/generator/fast-capture-vectors.test.ts \
 *      src/__vectors__/__tests__/
 *   npx jest src/__vectors__ --selectProjects logic
 *   rm -r src/__vectors__
 *
 * The JSON lands next to this folder, in Tests/InventoryServicesTests/Fixtures/capture/fast-capture.json.
 */
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

import type { ItemWithContext } from '@/db/types';
import type { RecognitionResult } from '@/services/ai/contract';
import { captureFastItem } from '@/services/capture/fastCapture';
import { sessionItems, summarizeSession } from '@/services/capture/fastReview';

const OUT = join(
  __dirname,
  '../../../native-ios/Packages/InventoryKit/Tests/InventoryServicesTests/Fixtures/capture',
);

/** Deterministic, so the file only changes when the TypeScript does. */
function lcg(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
}

function row(id: string, name: string, createdAt: number): ItemWithContext {
  return {
    id,
    containerId: 'c1',
    name,
    category: null,
    quantity: 1,
    notes: null,
    createdAt,
    updatedAt: createdAt,
    photoId: null,
    photoUri: null,
    photoThumbUri: null,
    tags: [],
    spaceId: 's1',
    spaceName: 'Garage',
    spaceIcon: '🚗',
    spaceColor: '#000',
    containerName: 'Shelf',
    containerShortCode: 'BOX-0000',
  };
}

// Names that JS `trim()` treats differently from a naive whitespace set.
const NAMES = [
  '',
  ' ',
  '\t\n',
  ' ',
  '﻿',
  '  ',
  '　',
  '​',
  '\u0085',
  '᠎',
  'Drill',
  '  Drill  ',
  ' Drill　',
  '﻿Drill﻿',
  'Dr ill',
  '​Drill',
  'é',
];

describe('capture vectors', () => {
  it('writes fast-capture.json', async () => {
    const random = lcg(0xc0ffee);

    const sessions = Array.from({ length: 40 }, (_, index) => {
      const count = Math.floor(random() * 8);
      const rows = Array.from({ length: count }, (_, n) => ({
        id: `r${index}-${n}`,
        createdAt: 100 + Math.floor(random() * 6) * 10,
      }));
      const since = 100 + Math.floor(random() * 7) * 10;
      const items = rows.map((value) => row(value.id, '', value.createdAt));
      return { since, rows, ids: sessionItems(items, since).map((item) => item.id) };
    });

    const summaries = Array.from({ length: 40 }, (_, index) => {
      const count = Math.floor(random() * 6);
      const names = Array.from({ length: count }, () => NAMES[Math.floor(random() * NAMES.length)]);
      const expected = Math.floor(random() * 8);
      const items = names.map((name, n) => row(`s${index}-${n}`, name, 1));
      return { names, expected, summary: summarizeSession(items, expected) };
    });

    const suggestionNames: (string | null)[] = [...NAMES, null];
    const pipeline = [];
    for (const name of suggestionNames) {
      for (const category of ['Tools', null]) {
        const updates: Record<string, unknown>[] = [];
        const created: Record<string, unknown>[] = [];
        const result = {
          status: 'success',
          contractVersion: 1,
          suggestion: { name, category, tags: ['dewalt'], confidence: 0.9 },
        } as unknown as RecognitionResult;
        const outcome = await captureFastItem({
          containerId: 'drop-zone',
          photoUri: 'file://a.jpg',
          deps: {
            storePhoto: async () => ({
              uri: 'file:///p.webp',
              thumbUri: 'file:///p-thumb.webp',
              width: 646,
              height: 1400,
              byteSize: null,
            }),
            createItem: async (draft) => {
              // JSON drops the undefined byteSize, as the draft omits an unknown size.
              created.push({ ...draft, hasName: 'name' in draft });
              return { id: 'item-1', updatedAt: 5 };
            },
            updateItem: async (_id, input) => {
              updates.push({ ...input, hasName: 'name' in input });
            },
            recognize: async () => result,
          },
        });
        pipeline.push({ name, category, outcome, updates, created });
      }
    }

    writeFileSync(
      join(OUT, 'fast-capture.json'),
      `${JSON.stringify({ sessions, summaries, pipeline }, null, 2)}\n`,
    );
  });
});
