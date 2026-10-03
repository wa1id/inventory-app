import type { ItemWithContext } from '@/db/types';
import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { strings } from '@/i18n/strings';
import type { ItemSearchResult, LocationSearchResult, SearchResults } from '@/repositories/search';
import {
  householdCounts,
  idleEntries,
  nameTotals,
  resultEntries,
  splitMatches,
  type HomeEntry,
} from '@/ui/home/homeList';

function item(id: string, overrides: Partial<ItemWithContext> = {}): ItemWithContext {
  return {
    id,
    containerId: 'c1',
    name: `Item ${id}`,
    category: null,
    quantity: 1,
    notes: null,
    createdAt: 0,
    updatedAt: 0,
    photoId: null,
    photoUri: null,
    photoThumbUri: null,
    tags: [],
    spaceId: 's1',
    spaceName: 'Garage',
    spaceIcon: '🧰',
    spaceColor: '#5B8DEF',
    containerName: 'Tool chest',
    containerShortCode: 'CAB-J92R',
    ...overrides,
  };
}

function hit(id: string, matchKind: 'direct' | 'location' = 'direct', overrides = {}) {
  return { ...item(id, overrides), matchKind } satisfies ItemSearchResult;
}

function place(id: string, kind: 'space' | 'container' = 'container'): LocationSearchResult {
  return { kind, id, title: id, subtitle: '', spaceId: 's1', itemCount: 0 };
}

function results(items: ItemSearchResult[], locations: LocationSearchResult[] = []): SearchResults {
  return { terms: ['x'], items, locations };
}

const kinds = (entries: HomeEntry[]) => entries.map((entry) => entry.kind);

describe('householdCounts', () => {
  it('adds the drop zone’s items but not its container', () => {
    expect(
      householdCounts(
        [
          { containerCount: 4, itemCount: 21 },
          { containerCount: 9, itemCount: 20 },
        ],
        4,
      ),
    ).toEqual({ spaces: 2, containers: 13, items: 45 });
  });

  it('counts an empty household as nothing', () => {
    expect(householdCounts([], 0)).toEqual({ spaces: 0, containers: 0, items: 0 });
  });

  it('reads as one sentence', () => {
    expect(strings.home.summary(5, 13, 45)).toBe('5 spaces, 13 containers and 45 items.');
    expect(strings.home.summary(1, 1, 1)).toBe('1 space, 1 container and 1 item.');
  });
});

describe('nameTotals', () => {
  it('adds up a name kept in two containers, ignoring case and spaces', () => {
    expect(
      nameTotals([
        { name: 'AA batteries', quantity: 12, containerId: 'c1' },
        { name: ' aa Batteries ', quantity: 2, containerId: 'c2' },
        { name: 'Drill', quantity: 1, containerId: 'c1' },
      ]),
    ).toEqual([{ name: 'AA batteries', quantity: 14, places: 2 }]);
  });

  it('says none are left when every place is empty', () => {
    const [total] = nameTotals([
      { name: 'Printer ink', quantity: 0, containerId: 'c1' },
      { name: 'Printer ink', quantity: 0, containerId: DROP_ZONE_CONTAINER_ID },
    ]);
    expect(total).toEqual({ name: 'Printer ink', quantity: 0, places: 2 });
    expect(strings.search.totalNone(total!.name, total!.places)).toBe(
      '“Printer ink”: none left in any of 2 places',
    );
  });

  it('counts places, not items, and needs a second place', () => {
    expect(
      nameTotals([
        { name: 'Screws', quantity: 10, containerId: 'c1' },
        { name: 'Screws', quantity: 5, containerId: 'c1' },
      ]),
    ).toEqual([]);
    expect(
      nameTotals([
        { name: 'Screws', quantity: 10, containerId: 'c1' },
        { name: 'Screws', quantity: 5, containerId: 'c1' },
        { name: 'Screws', quantity: 1, containerId: 'c2' },
      ]),
    ).toEqual([{ name: 'Screws', quantity: 16, places: 2 }]);
  });

  it('never totals unnamed items', () => {
    expect(
      nameTotals([
        { name: '', quantity: 1, containerId: 'c1' },
        { name: '  ', quantity: 1, containerId: 'c2' },
      ]),
    ).toEqual([]);
  });

  it('keeps the order the names first appear in', () => {
    const totals = nameTotals([
      { name: 'Tape', quantity: 1, containerId: 'c1' },
      { name: 'Glue', quantity: 1, containerId: 'c1' },
      { name: 'Glue', quantity: 1, containerId: 'c2' },
      { name: 'Tape', quantity: 1, containerId: 'c2' },
    ]);
    expect(totals.map((total) => total.name)).toEqual(['Tape', 'Glue']);
  });
});

describe('idleEntries', () => {
  const recent = [item('a'), item('b'), item('c')];

  it('shows the notice, the card and then Recently added with sheet positions', () => {
    const entries = idleEntries({
      notice: true,
      refreshFailed: false,
      dropZoneCount: 2,
      body: { kind: 'list', recent, canShowMore: true },
    });
    expect(kinds(entries)).toEqual(['notice', 'dropZone', 'title', 'item', 'item', 'item', 'more']);
    const title = entries[2];
    expect(title).toMatchObject({ title: 'Recently added', count: 3, first: false });
    expect(entries.filter((entry) => entry.kind === 'item').map((entry) => entry.position)).toEqual(
      [
        { index: 0, count: 3 },
        { index: 1, count: 3 },
        { index: 2, count: 3 },
      ],
    );
  });

  it('leaves out the card when nothing is waiting, and the section when nothing is stored', () => {
    expect(
      kinds(
        idleEntries({
          notice: false,
          refreshFailed: false,
          dropZoneCount: 0,
          body: { kind: 'list', recent: [], canShowMore: false },
        }),
      ),
    ).toEqual([]);
  });

  it('puts the section first when nothing comes before it', () => {
    const [title] = idleEntries({
      notice: false,
      refreshFailed: false,
      dropZoneCount: 0,
      body: { kind: 'list', recent, canShowMore: false },
    });
    expect(title).toMatchObject({ kind: 'title', first: true });
  });

  it('shows a status in place of the list, and the stale-data notice on top', () => {
    expect(
      kinds(
        idleEntries({
          notice: false,
          refreshFailed: true,
          dropZoneCount: 1,
          body: { kind: 'status', status: 'error' },
        }),
      ),
    ).toEqual(['refreshFailed', 'dropZone', 'status']);
  });
});

describe('resultEntries', () => {
  it('orders items, places, then items kept in those places', () => {
    const entries = resultEntries(
      results(
        [hit('d1'), hit('l1', 'location'), hit('d2'), hit('l2', 'location')],
        [place('box'), place('garage', 'space')],
      ),
      false,
    );
    expect(kinds(entries)).toEqual([
      'summary',
      'title',
      'item',
      'item',
      'title',
      'place',
      'place',
      'title',
      'item',
      'item',
    ]);
    expect(entries[0]).toMatchObject({ text: '4 items and 2 places found' });
    expect(
      entries.filter((entry) => entry.kind === 'title').map((entry) => [entry.title, entry.first]),
    ).toEqual([
      ['Items', true],
      ['Spaces and containers', false],
      ['Kept in those places', false],
    ]);
  });

  it('gives every entry its own key, even an id that is both a place and a row', () => {
    const entries = resultEntries(results([hit('x'), hit('y', 'location')], [place('x')]), false);
    const keys = entries.map((entry) => entry.key);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it('puts the totals at the top of the items', () => {
    const entries = resultEntries(
      results([
        hit('a', 'direct', { name: 'AA batteries', quantity: 12, containerId: 'c1' }),
        hit('b', 'direct', { name: 'AA batteries', quantity: 2, containerId: 'c2' }),
      ]),
      false,
    );
    expect(kinds(entries)).toEqual(['title', 'totals', 'item', 'item']);
    expect(entries[1]).toMatchObject({
      totals: [{ name: 'AA batteries', quantity: 14, places: 2 }],
    });
  });

  it('starts with the first section that has anything', () => {
    const entries = resultEntries(results([hit('a', 'location')], [place('box')]), false);
    expect(kinds(entries)).toEqual(['summary', 'title', 'place', 'title', 'item']);
    expect(entries[1]).toMatchObject({ title: 'Spaces and containers', first: true });
    expect(entries[0]).toMatchObject({ text: '1 item and 1 place found' });
  });

  it('leaves the summary to the section title when there is one section', () => {
    expect(kinds(resultEntries(results([hit('a'), hit('b')]), false))).toEqual([
      'title',
      'item',
      'item',
    ]);
    const entries = resultEntries(results([], [place('box')]), false);
    expect(kinds(entries)).toEqual(['title', 'place']);
    expect(entries[0]).toMatchObject({ title: 'Spaces and containers', count: 1, first: true });
  });

  it('says nothing was found as a status, not an empty list', () => {
    expect(resultEntries(results([]), true)).toEqual([
      { kind: 'status', key: 'status', status: 'noResults' },
    ]);
  });

  it('keeps the results under the stale-data notice when a refresh failed', () => {
    expect(kinds(resultEntries(results([hit('a')]), true)).slice(0, 2)).toEqual([
      'refreshFailed',
      'title',
    ]);
    expect(kinds(resultEntries(results([hit('a')], [place('box')]), true)).slice(0, 2)).toEqual([
      'refreshFailed',
      'summary',
    ]);
  });
});

describe('splitMatches', () => {
  it('keeps each kind in the order the search returned it', () => {
    const { direct, location } = splitMatches([
      hit('1'),
      hit('2', 'location'),
      hit('3'),
      hit('4', 'location'),
    ]);
    expect(direct.map((entry) => entry.id)).toEqual(['1', '3']);
    expect(location.map((entry) => entry.id)).toEqual(['2', '4']);
  });
});

describe('search copy', () => {
  it('summarises what was found', () => {
    expect(strings.search.summary(3, 1)).toBe('3 items and 1 place found');
    expect(strings.search.summary(1, 0)).toBe('1 item found');
    expect(strings.search.summary(0, 0)).toBe('Nothing found');
  });

  it('reads the total line as one sentence', () => {
    expect(strings.search.total('AA batteries', 14, 2)).toBe('“AA batteries”: ×14 in 2 places');
  });
});
