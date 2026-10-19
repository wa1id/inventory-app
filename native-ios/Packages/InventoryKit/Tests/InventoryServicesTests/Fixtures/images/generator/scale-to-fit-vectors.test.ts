/**
 * Generates the `scaleToFit` parity vectors from the real TypeScript.
 *
 * Not part of the RN test suite. To regenerate (see native-ios/docs/CONVENTIONS.md):
 *
 *   ln -s /home/walid/inventory-app/node_modules node_modules   # once, in a worktree
 *   mkdir -p src/__vectors__/__tests__
 *   cp native-ios/Packages/InventoryKit/Tests/InventoryServicesTests/Fixtures/images/generator/scale-to-fit-vectors.test.ts \
 *      src/__vectors__/__tests__/
 *   npx jest src/__vectors__ --selectProjects logic
 *   rm -r src/__vectors__
 *
 * The JSON lands next to this folder, in Tests/InventoryServicesTests/Fixtures/images/.
 */
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

import {
  IMAGE_QUALITY,
  MAX_IMAGE_DIMENSION,
  THUMBNAIL_DIMENSION,
  THUMBNAIL_QUALITY,
  scaleToFit,
} from '@/services/capture/imageScaling';

const OUT = join(
  __dirname,
  '../../../native-ios/Packages/InventoryKit/Tests/InventoryServicesTests/Fixtures/images',
);

type Vector = [number, number, number, number | null, number | null];

/** Deterministic, so the file only changes when the TypeScript does. */
function lcg(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
}

it('writes scale-to-fit.json', () => {
  const cases: [number, number, number][] = [];
  const edges = [MAX_IMAGE_DIMENSION, THUMBNAIL_DIMENSION];

  // Camera, screenshot and library sizes, both ways round.
  const sizes = [
    [4032, 3024], [3024, 4032], [4000, 3000], [5712, 4284], [8064, 6048], [1920, 1080],
    [1080, 1920], [2048, 1536], [1179, 2556], [1290, 2796], [1863, 4032], [4032, 1863],
    [1050, 1400], [1400, 1050], [1400, 1400], [1401, 1401], [1401, 1], [1, 1401],
    [800, 600], [320, 240], [240, 320], [321, 320], [320, 321], [1399, 20], [1, 1],
    [20_000, 3], [3, 20_000], [16_383, 16_383], [646, 1400], [1400, 646],
  ];
  for (const edge of edges) {
    for (const [w, h] of sizes) cases.push([w!, h!, edge]);
  }

  // Exact .5 products: JS Math.round rounds half up, so these pin the rounding rule.
  for (const edge of edges) {
    for (let short = 1; short <= 41; short += 2) {
      cases.push([edge * 2, short, edge]);
      cases.push([short, edge * 2, edge]);
      cases.push([edge * 4, short * 2, edge]);
    }
  }

  // A dense sweep just above each edge, where scales are close to 1.
  for (const edge of edges) {
    for (let long = edge - 2; long <= edge + 60; long += 1) {
      for (const short of [1, 2, 3, 7, Math.floor(long / 3), Math.floor(long / 2), long - 1, long]) {
        cases.push([long, short, edge]);
        cases.push([short, long, edge]);
      }
    }
  }

  // Seeded random sizes up to 12 000 px.
  const random = lcg(0x5ca1ab1e);
  for (let i = 0; i < 1500; i += 1) {
    const w = 1 + Math.floor(random() * 12_000);
    const h = 1 + Math.floor(random() * 12_000);
    cases.push([w, h, edges[i % 2]!]);
  }

  const vectors: Vector[] = cases.map(([w, h, edge]) => {
    const target = scaleToFit(w, h, edge);
    return [w, h, edge, target?.width ?? null, target?.height ?? null];
  });

  writeFileSync(
    join(OUT, 'scale-to-fit.json'),
    `${JSON.stringify(
      {
        constants: {
          MAX_IMAGE_DIMENSION,
          IMAGE_QUALITY,
          THUMBNAIL_DIMENSION,
          THUMBNAIL_QUALITY,
        },
        // [width, height, maxEdge, targetWidth | null, targetHeight | null]
        vectors,
      },
      null,
      0,
    )}\n`,
  );
});
