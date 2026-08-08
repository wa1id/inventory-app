import { sessionItems, summarizeSession } from '@/services/capture/fastReview';
import type { ItemWithContext } from '@/db/types';

function item(overrides: Partial<ItemWithContext>): ItemWithContext {
  return {
    id: 'item-1',
    containerId: 'container-1',
    name: '',
    category: null,
    quantity: 1,
    notes: null,
    createdAt: 0,
    updatedAt: 0,
    photoUri: null,
    photoThumbUri: null,
    tags: [],
    spaceId: 'space-1',
    spaceName: 'Garage',
    spaceIcon: '🚗',
    spaceColor: '#000',
    containerName: 'Shelf',
    containerShortCode: 'BOX-0000',
    ...overrides,
  };
}

describe('sessionItems', () => {
  it('keeps only items created during the session, oldest first', () => {
    const rows = [
      item({ id: 'newest', createdAt: 300 }),
      item({ id: 'older', createdAt: 200 }),
      item({ id: 'pre-session', createdAt: 99 }),
    ];

    expect(sessionItems(rows, 100).map((row) => row.id)).toEqual(['older', 'newest']);
  });

  it('includes an item created exactly at the session start', () => {
    expect(sessionItems([item({ createdAt: 100 })], 100)).toHaveLength(1);
  });
});

describe('summarizeSession', () => {
  it('splits saved rows into named and unnamed', () => {
    const rows = [
      item({ id: 'a', name: 'Drill' }),
      item({ id: 'b', name: '' }),
      item({ id: 'c', name: '   ' }),
    ];

    expect(summarizeSession(rows, 3)).toEqual({ saved: 3, named: 1, unnamed: 2, pending: 0 });
  });

  it('reports rows the pipeline has not landed yet as pending', () => {
    expect(summarizeSession([item({})], 3).pending).toBe(2);
  });

  it('never reports negative pending when a reported shot failed to write', () => {
    expect(summarizeSession([item({}), item({ id: 'b' })], 1).pending).toBe(0);
  });
});
