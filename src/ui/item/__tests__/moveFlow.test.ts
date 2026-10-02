import { ConflictError } from '@/core/conflict';
import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { HouseholdHttpError } from '@/services/household/client';
import {
  attemptMove,
  attemptUndo,
  containerLabel,
  moveFailedMessage,
  movedElsewhereMessage,
  movedMessage,
  nextInRun,
  runPosition,
  undoFailedMessage,
  type MoveItems,
  type MoveSubject,
} from '@/ui/item/moveFlow';

type Call = { id: string; containerId: string; expectedUpdatedAt: number };

/** A fake `repos.items` that answers each call from a script. */
function fakeItems(script: {
  updates: (() => Promise<{ updatedAt: number } | null>)[];
  fresh?: () => Promise<MoveSubject | null>;
}) {
  const calls: Call[] = [];
  const reads: string[] = [];
  const items: MoveItems<MoveSubject> = {
    update(id, input) {
      calls.push({ id, ...input });
      const next = script.updates.shift();
      if (!next) throw new Error('unexpected update');
      return next();
    },
    getById(id) {
      reads.push(id);
      return script.fresh ? script.fresh() : Promise.resolve(null);
    },
  };
  return { items, calls, reads };
}

const before: MoveSubject = { id: 'item-1', containerId: 'box-a', updatedAt: 100 };

describe('attemptMove', () => {
  it('moves with the lock the item had', async () => {
    const { items, calls } = fakeItems({ updates: [async () => ({ updatedAt: 200 })] });
    await expect(attemptMove(items, before, 'box-b')).resolves.toEqual({
      kind: 'moved',
      updatedAt: 200,
    });
    expect(calls).toEqual([{ id: 'item-1', containerId: 'box-b', expectedUpdatedAt: 100 }]);
  });

  it('reports a null update as gone, never as moved', async () => {
    const { items } = fakeItems({ updates: [async () => null] });
    await expect(attemptMove(items, before, 'box-b')).resolves.toEqual({ kind: 'gone' });
  });

  it('stops when another phone moved it first, and says where it is', async () => {
    const fresh = { id: 'item-1', containerId: 'box-c', updatedAt: 150 };
    const { items, calls } = fakeItems({
      updates: [
        async () => {
          throw new ConflictError(150);
        },
      ],
      fresh: async () => fresh,
    });
    await expect(attemptMove(items, before, 'box-b')).resolves.toEqual({
      kind: 'movedElsewhere',
      fresh,
    });
    expect(calls).toHaveLength(1);
  });

  it('retries once with the new stamp when only something else changed', async () => {
    const { items, calls } = fakeItems({
      updates: [
        async () => {
          throw new ConflictError(150);
        },
        async () => ({ updatedAt: 300 }),
      ],
      fresh: async () => ({ id: 'item-1', containerId: 'box-a', updatedAt: 150 }),
    });
    await expect(attemptMove(items, before, 'box-b')).resolves.toEqual({
      kind: 'moved',
      updatedAt: 300,
    });
    expect(calls.map((call) => call.expectedUpdatedAt)).toEqual([100, 150]);
  });

  it('gives up after one retry', async () => {
    const second = new ConflictError(160);
    const { items, calls } = fakeItems({
      updates: [
        async () => {
          throw new ConflictError(150);
        },
        async () => {
          throw second;
        },
      ],
      fresh: async () => ({ id: 'item-1', containerId: 'box-a', updatedAt: 150 }),
    });
    await expect(attemptMove(items, before, 'box-b')).resolves.toEqual({
      kind: 'failed',
      cause: second,
    });
    expect(calls).toHaveLength(2);
  });

  it('treats an item deleted between the conflict and the re-read as gone', async () => {
    const { items } = fakeItems({
      updates: [
        async () => {
          throw new ConflictError(150);
        },
      ],
      fresh: async () => null,
    });
    await expect(attemptMove(items, before, 'box-b')).resolves.toEqual({ kind: 'gone' });
  });

  it('passes any other failure through without retrying', async () => {
    const offline = new HouseholdHttpError(0, 'offline');
    const { items, calls, reads } = fakeItems({
      updates: [
        async () => {
          throw offline;
        },
      ],
    });
    await expect(attemptMove(items, before, 'box-b')).resolves.toEqual({
      kind: 'failed',
      cause: offline,
    });
    expect(calls).toHaveLength(1);
    expect(reads).toHaveLength(0);
  });
});

describe('attemptUndo', () => {
  const move = { itemId: 'item-1', from: 'box-a', updatedAt: 200 };

  it('moves it back with the stamp the move left', async () => {
    const { items, calls } = fakeItems({ updates: [async () => ({ updatedAt: 250 })] });
    await expect(attemptUndo(items, move)).resolves.toBe('undone');
    expect(calls).toEqual([{ id: 'item-1', containerId: 'box-a', expectedUpdatedAt: 200 }]);
  });

  it('tells deleted, changed again and failed apart', async () => {
    await expect(attemptUndo(fakeItems({ updates: [async () => null] }).items, move)).resolves.toBe(
      'gone',
    );
    await expect(
      attemptUndo(
        fakeItems({
          updates: [
            async () => {
              throw new ConflictError(260);
            },
          ],
        }).items,
        move,
      ),
    ).resolves.toBe('conflict');
    await expect(
      attemptUndo(
        fakeItems({
          updates: [
            async () => {
              throw new HouseholdHttpError(0, 'offline');
            },
          ],
        }).items,
        move,
      ),
    ).resolves.toBe('failed');
  });

  it('words each refusal differently', () => {
    expect(undoFailedMessage('gone')).toMatch(/deleted/);
    expect(undoFailedMessage('conflict')).toMatch(/changed again/);
    expect(undoFailedMessage('failed')).toMatch(/connection/);
  });
});

describe('messages', () => {
  it('names an unnamed container by its label code', () => {
    expect(containerLabel({ name: null, shortCode: 'CAB-J92R' })).toBe('CAB-J92R');
    expect(containerLabel({ name: 'Tool chest', shortCode: 'CAB-J92R' })).toBe('Tool chest');
  });

  it('says moved, filed, next one or everything filed', () => {
    const where = { container: 'Tool chest', space: 'Garage' };
    expect(movedMessage({ ...where, fromDropZone: false, filing: false, moreWaiting: false })).toBe(
      'Moved to Tool chest (Garage)',
    );
    expect(movedMessage({ ...where, fromDropZone: true, filing: false, moreWaiting: true })).toBe(
      'Filed in Tool chest (Garage)',
    );
    expect(movedMessage({ ...where, fromDropZone: true, filing: true, moreWaiting: true })).toBe(
      'Filed in Tool chest (Garage). Next one.',
    );
    expect(movedMessage({ ...where, fromDropZone: true, filing: true, moreWaiting: false })).toBe(
      'Filed in Tool chest (Garage). Everything is filed.',
    );
  });

  it('says where another phone moved it, never the drop zone code', () => {
    expect(
      movedElsewhereMessage({
        containerId: 'box-c',
        containerName: 'Garage shelf',
        containerShortCode: 'SHF-1',
      }),
    ).toBe('Someone already moved it to Garage shelf on another device.');
    expect(
      movedElsewhereMessage({
        containerId: 'box-c',
        containerName: null,
        containerShortCode: 'SHF-1',
      }),
    ).toBe('Someone already moved it to SHF-1 on another device.');
    expect(
      movedElsewhereMessage({
        containerId: DROP_ZONE_CONTAINER_ID,
        containerName: 'Drop zone',
        containerShortCode: 'DROP-ZONE',
      }),
    ).not.toMatch(/DROP-ZONE/);
  });

  it('only blames the connection when it was the connection', () => {
    expect(moveFailedMessage(new HouseholdHttpError(0, 'offline'))).toMatch(/connection/);
    expect(moveFailedMessage(new HouseholdHttpError(502, 'http_502'))).toMatch(/connection/);
    expect(moveFailedMessage(new Error('SQLITE_BUSY'))).toBe('It was not moved. Try again.');
  });
});

describe('nextInRun', () => {
  it('takes the item after this one', () => {
    expect(nextInRun(['a', 'b', 'c'], 'a', ['b', 'c'])).toBe('b');
  });

  it('wraps round to the top', () => {
    expect(nextInRun(['a', 'b', 'c'], 'c', ['a', 'b'])).toBe('a');
  });

  it('skips items filed or deleted meanwhile', () => {
    expect(nextInRun(['a', 'b', 'c', 'd'], 'a', ['c', 'd'])).toBe('c');
  });

  it('never returns this item, even if it is still waiting', () => {
    expect(nextInRun(['a', 'b'], 'a', ['a', 'b'])).toBe('b');
    expect(nextInRun(['a'], 'a', ['a'])).toBeNull();
  });

  it('takes items that arrived meanwhile once the old ones are done', () => {
    expect(nextInRun(['a', 'b'], 'a', ['z'])).toBe('z');
  });

  it('starts from the top when this item was not in the list', () => {
    expect(nextInRun(['a', 'b'], 'x', ['b', 'a'])).toBe('a');
  });

  it('ends the run when nothing is left', () => {
    expect(nextInRun(['a', 'b'], 'a', [])).toBeNull();
    expect(nextInRun([], 'a', [])).toBeNull();
  });
});

describe('runPosition', () => {
  it('counts from one', () => {
    expect(runPosition(['a', 'b', 'c', 'd', 'e'], 'b')).toEqual({ index: 2, total: 5 });
  });

  it('is null for an item that is not waiting', () => {
    expect(runPosition(['a'], 'b')).toBeNull();
  });
});
