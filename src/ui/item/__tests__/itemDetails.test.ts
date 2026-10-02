import { ConflictError } from '@/core/conflict';
import {
  attemptDetails,
  attemptName,
  detailsDirty,
  detailsSeed,
  itemStamp,
  keepsUnnamed,
} from '@/ui/item/itemDetails';

const item = {
  name: 'Cordless drill',
  category: 'Tools',
  tags: ['garage', 'power'],
  notes: null,
  quantity: 2,
};

describe('detailsSeed', () => {
  it('turns the stored item into form values', () => {
    expect(detailsSeed(item)).toEqual({
      name: 'Cordless drill',
      category: 'Tools',
      tags: 'garage, power',
      quantity: '2',
      notes: '',
    });
  });
});

describe('detailsDirty', () => {
  const seed = detailsSeed(item);

  it('is clean as seeded and with only spaces added', () => {
    expect(detailsDirty(seed, seed)).toBe(false);
    expect(detailsDirty({ ...seed, name: ' Cordless drill ', tags: 'garage,power ' }, seed)).toBe(
      false,
    );
  });

  it('is dirty when any field really changes', () => {
    expect(detailsDirty({ ...seed, name: 'Drill' }, seed)).toBe(true);
    expect(detailsDirty({ ...seed, category: '' }, seed)).toBe(true);
    expect(detailsDirty({ ...seed, tags: 'garage' }, seed)).toBe(true);
    expect(detailsDirty({ ...seed, notes: 'Charger in the bag' }, seed)).toBe(true);
  });

  it('ignores the quantity, which this form does not edit', () => {
    expect(detailsDirty({ ...seed, quantity: '5' }, seed)).toBe(false);
  });
});

describe('keepsUnnamed', () => {
  it('lets an unnamed item stay unnamed', () => {
    expect(keepsUnnamed('', '')).toBe(true);
    expect(keepsUnnamed('', '   ')).toBe(true);
  });

  it('requires a name once one is typed or the item had one', () => {
    expect(keepsUnnamed('', 'Batteries')).toBe(false);
    expect(keepsUnnamed('Batteries', '')).toBe(false);
  });
});

describe('itemStamp', () => {
  const created = Date.UTC(2026, 8, 2, 12);
  const day = 24 * 60 * 60 * 1000;

  it('says when it was added', () => {
    expect(itemStamp(created, created + 30_000, created + 3 * day)).toBe('Added 2 September 2026.');
  });

  it('adds the last change once it is more than a minute after adding', () => {
    expect(itemStamp(created, created + day, created + 4 * day)).toBe(
      'Added 2 September 2026. Last changed 3 days ago.',
    );
  });
});

describe('attemptName', () => {
  type Answer = () => Promise<{ updatedAt: number } | null>;

  function fake(updates: Answer[], fresh: { name: string; updatedAt: number } | null = null) {
    const stamps: number[] = [];
    return {
      stamps,
      items: {
        update(_id: string, input: { name: string; expectedUpdatedAt: number }) {
          stamps.push(input.expectedUpdatedAt);
          const next = updates.shift();
          if (!next) throw new Error('unexpected update');
          return next();
        },
        getById: async () => fresh,
      },
    };
  }

  const conflict: Answer = async () => {
    throw new ConflictError(20);
  };
  const unnamed = { id: 'item-1', updatedAt: 10 };

  it('names it with the lock it had', async () => {
    const { items, stamps } = fake([async () => ({ updatedAt: 11 })]);
    await expect(attemptName(items, unnamed, 'Batteries')).resolves.toEqual({ kind: 'named' });
    expect(stamps).toEqual([10]);
  });

  it('reports a null update as gone', async () => {
    const { items } = fake([async () => null]);
    await expect(attemptName(items, unnamed, 'Batteries')).resolves.toEqual({ kind: 'gone' });
  });

  it('keeps a name given on another phone meanwhile', async () => {
    const { items, stamps } = fake([conflict], { name: 'AA batteries', updatedAt: 20 });
    await expect(attemptName(items, unnamed, 'Batteries')).resolves.toEqual({
      kind: 'namedElsewhere',
      name: 'AA batteries',
    });
    expect(stamps).toEqual([10]);
  });

  it('retries once when something else changed', async () => {
    const { items, stamps } = fake([conflict, async () => ({ updatedAt: 21 })], {
      name: '',
      updatedAt: 20,
    });
    await expect(attemptName(items, unnamed, 'Batteries')).resolves.toEqual({ kind: 'named' });
    expect(stamps).toEqual([10, 20]);
  });

  it('fails without retrying anything but a conflict', async () => {
    const cause = new Error('offline');
    const { items, stamps } = fake([
      async () => {
        throw cause;
      },
    ]);
    await expect(attemptName(items, unnamed, 'Batteries')).resolves.toEqual({
      kind: 'failed',
      cause,
    });
    expect(stamps).toEqual([10]);
  });
});

describe('attemptDetails', () => {
  type Answer = () => Promise<{ updatedAt: number } | null>;
  type Fresh = Parameters<typeof detailsSeed>[0] & { updatedAt: number };

  function fake(updates: Answer[], fresh: Fresh | null = null) {
    const stamps: number[] = [];
    return {
      stamps,
      items: {
        update(_id: string, input: { expectedUpdatedAt: number }) {
          stamps.push(input.expectedUpdatedAt);
          const next = updates.shift();
          if (!next) throw new Error('unexpected update');
          return next();
        },
        getById: async () => fresh,
      },
    };
  }

  const conflict: Answer = async () => {
    throw new ConflictError(20);
  };
  const base = { updatedAt: 10, values: detailsSeed(item) };
  const patch = { name: 'Drill', category: 'Tools', tags: ['garage'], notes: null };

  it('saves over the version the form was filled from', async () => {
    const { items, stamps } = fake([async () => ({ updatedAt: 11 })]);
    await expect(attemptDetails(items, 'item-1', patch, base)).resolves.toEqual({
      kind: 'saved',
    });
    expect(stamps).toEqual([10]);
  });

  it('reports a null update as gone', async () => {
    const { items } = fake([async () => null]);
    await expect(attemptDetails(items, 'item-1', patch, base)).resolves.toEqual({
      kind: 'gone',
    });
  });

  it('saves once more when only the quantity changed meanwhile', async () => {
    const { items, stamps } = fake([conflict, async () => ({ updatedAt: 21 })], {
      ...item,
      quantity: 3,
      updatedAt: 20,
    });
    await expect(attemptDetails(items, 'item-1', patch, base)).resolves.toEqual({
      kind: 'saved',
    });
    expect(stamps).toEqual([10, 20]);
  });

  it('stops at a change to these details and hands back their version', async () => {
    const theirs = { ...item, notes: 'Charger in the bag', updatedAt: 20 };
    const { items, stamps } = fake([conflict], theirs);
    await expect(attemptDetails(items, 'item-1', patch, base)).resolves.toEqual({
      kind: 'conflict',
      base: { updatedAt: 20, values: detailsSeed(theirs) },
    });
    expect(stamps).toEqual([10]);
  });

  it('treats an item deleted after the conflict as gone', async () => {
    const { items } = fake([conflict], null);
    await expect(attemptDetails(items, 'item-1', patch, base)).resolves.toEqual({
      kind: 'gone',
    });
  });

  it('gives up after one retry', async () => {
    const { items, stamps } = fake([conflict, conflict], { ...item, updatedAt: 20 });
    const outcome = await attemptDetails(items, 'item-1', patch, base);
    expect(outcome.kind).toBe('failed');
    expect(stamps).toEqual([10, 20]);
  });

  it('fails without retrying anything but a conflict', async () => {
    const cause = new Error('offline');
    const { items, stamps } = fake([
      async () => {
        throw cause;
      },
    ]);
    await expect(attemptDetails(items, 'item-1', patch, base)).resolves.toEqual({
      kind: 'failed',
      cause,
    });
    expect(stamps).toEqual([10]);
  });
});
