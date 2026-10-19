/**
 * Generates the capture and scan parity vectors for InventoryAppModels from the real TypeScript:
 * src/ui/capture/captureFlow.ts (every status, title, toast and count rule over a grid) and
 * src/ui/scan/scanRules.ts (labelFor, tokenParam, planBind, linkFailureMessage).
 *
 * Not part of the RN test suite. To regenerate (see native-ios/docs/CONVENTIONS.md):
 *
 *   ln -s /home/walid/inventory-app/node_modules node_modules   # once, in a worktree
 *   mkdir -p src/__vectors__/__tests__
 *   cp native-ios/Packages/InventoryKit/Tests/InventoryAppModelsTests/Fixtures/capture/generator/capture-flow-vectors.test.ts \
 *      src/__vectors__/__tests__/
 *   npx jest src/__vectors__ --selectProjects logic
 *   rm -r src/__vectors__
 *
 * The JSON lands next to this folder, in Tests/InventoryAppModelsTests/Fixtures/capture/capture-flow.json.
 */
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { HouseholdHttpError } from '@/services/household/client';
import {
  expectedStillShown,
  fastStatus,
  intoA11y,
  leaveCamera,
  reviewDoneToast,
  reviewStatus,
  reviewStatusText,
  reviewTitle,
} from '@/ui/capture/captureFlow';
import { labelFor, linkFailureMessage, planBind, tokenParam } from '@/ui/scan/scanRules';

const OUT = join(
  __dirname,
  '../../../native-ios/Packages/InventoryKit/Tests/InventoryAppModelsTests/Fixtures/capture',
);

const WHITESPACE_NAMES = ['', ' ', ' ', '﻿', '　', '​', ' ', 'Tool chest', ' Tool chest ', ' Box '];

describe('capture-flow vectors', () => {
  it('writes capture-flow.json', () => {
    const fast = [];
    for (let captured = 0; captured <= 4; captured += 1) {
      for (let completed = 0; completed <= captured; completed += 1) {
        for (let recognized = 0; recognized <= completed; recognized += 1) {
          fast.push({ captured, completed, recognized, ...fastStatus({ captured, completed, recognized }) });
        }
      }
    }

    const leave = [];
    for (const mode of ['single', 'fast'] as const) {
      for (const captured of [0, 1, 2]) leave.push({ mode, captured, result: leaveCamera(mode, captured) });
    }

    const review = [];
    for (let saved = 0; saved <= 3; saved += 1) {
      for (let unnamed = 0; unnamed <= saved; unnamed += 1) {
        for (let pending = 0; pending <= 3; pending += 1) {
          for (const stalled of [false, true]) {
            for (const containerId of [DROP_ZONE_CONTAINER_ID, 'c1']) {
              for (const label of [null, 'Tool chest', '']) {
                const summary = { saved, named: saved - unnamed, unnamed, pending };
                const status = reviewStatus(summary, stalled);
                review.push({
                  summary,
                  stalled,
                  containerId,
                  label,
                  status,
                  statusText: reviewStatusText(status, summary),
                  title: reviewTitle(summary, status, containerId, label),
                });
              }
            }
          }
        }
      }
    }

    const toasts = [];
    for (const saved of [0, 1, 2, 12]) {
      for (const containerId of [DROP_ZONE_CONTAINER_ID, 'c1']) {
        for (const label of [null, 'Tool chest']) {
          toasts.push({ saved, containerId, label, toast: reviewDoneToast(saved, containerId, label) });
        }
      }
    }

    const expected = [];
    for (let e = 0; e <= 4; e += 1) {
      for (let landed = 0; landed <= 4; landed += 1) {
        for (let shown = 0; shown <= 4; shown += 1) {
          expected.push({ expected: e, landed, shown, result: expectedStillShown(e, landed, shown) });
        }
      }
    }

    const into = [];
    for (const containerId of [DROP_ZONE_CONTAINER_ID, 'c1']) {
      for (const name of [null, '', ' ', 'Tool chest']) {
        for (const code of ['CAB-J92R', 'BOX1', '-AB--C-', ' DRW - 7K2M ']) {
          const place = {
            containerId,
            containerName: name,
            containerShortCode: code,
            spaceId: 's1',
            spaceName: 'Garage',
            spaceColor: '#5B8DEF',
          };
          into.push({ containerId, name, code, result: intoA11y(containerId, place) });
        }
      }
      into.push({ containerId, name: null, code: null, result: intoA11y(containerId, null) });
    }

    const labels = WHITESPACE_NAMES.map((name) => ({ name, result: labelFor({ name, shortCode: 'BOX-7K2M' }) }));
    labels.push({ name: null as unknown as string, result: labelFor({ name: null, shortCode: 'BOX-7K2M' }) });

    const tokens = [' abc ', ' abc﻿', '', '　', 'a b'].map((value) => ({ value, result: tokenParam(value) }));

    const token = 'a'.repeat(32);
    const plans = [null, token, token.toUpperCase(), 'b'.repeat(32), 'İ'.repeat(32)].map((existing) => ({
      existing,
      label: 'Tool chest',
      plan: planBind(existing === null ? null : { token: existing }, token, 'Tool chest'),
    }));

    const failures = [
      [0, 'offline'],
      [0, 'timeout'],
      [502, 'http_502'],
      [520, 'origin_down'],
      [530, 'http_530'],
      [531, 'http_531'],
      [404, 'not_found'],
      [410, 'gone'],
      [401, 'unauthorized'],
      [403, 'unauthorized'],
      [409, 'conflict'],
      [500, 'http_500'],
      [400, 'system_record'],
      [200, 'photo_missing'],
    ].map(([status, code]) => ({
      status,
      code,
      message: linkFailureMessage(new HouseholdHttpError(status as number, code as string)),
    }));
    const local = linkFailureMessage(new Error('SQLITE_CONSTRAINT'));

    writeFileSync(
      join(OUT, 'capture-flow.json'),
      `${JSON.stringify({ fast, leave, review, toasts, expected, into, labels, tokens, plans, failures, local }, null, 2)}\n`,
    );
  });
});
