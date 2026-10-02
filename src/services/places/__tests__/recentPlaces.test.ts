import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import {
  MAX_RECENT_PLACES,
  mergeRecent,
  readRecentPlaces,
  rememberPlace,
} from '@/services/places/recentPlaces';

const mockPreferences = new Map<string, string>();

jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: async (key: string) => mockPreferences.get(key) ?? null,
    setItem: async (key: string, value: string) => {
      mockPreferences.set(key, value);
    },
  },
}));

describe('mergeRecent', () => {
  it('puts the place first', () => {
    expect(mergeRecent(['a', 'b'], 'c')).toEqual(['c', 'a', 'b']);
  });

  it('moves a place already in the list to the front instead of repeating it', () => {
    expect(mergeRecent(['a', 'b', 'c'], 'b')).toEqual(['b', 'a', 'c']);
  });

  it('keeps at most six', () => {
    const full = ['a', 'b', 'c', 'd', 'e', 'f'];
    expect(MAX_RECENT_PLACES).toBe(6);
    expect(mergeRecent(full, 'g')).toEqual(['g', 'a', 'b', 'c', 'd', 'e']);
    expect(mergeRecent(full, 'g', 3)).toEqual(['g', 'a', 'b']);
  });

  it('never stores the drop zone', () => {
    expect(mergeRecent(['a'], DROP_ZONE_CONTAINER_ID)).toEqual(['a']);
    expect(mergeRecent([DROP_ZONE_CONTAINER_ID, 'a'], 'b')).toEqual(['b', 'a']);
  });
});

describe('rememberPlace', () => {
  it('persists the merged list and reads it back', async () => {
    await rememberPlace('a');
    await rememberPlace('b');
    await rememberPlace(DROP_ZONE_CONTAINER_ID);
    await rememberPlace('a');
    expect(await readRecentPlaces()).toEqual(['a', 'b']);
    expect(JSON.parse(mockPreferences.get('places.recent.v1') ?? '[]')).toEqual(['a', 'b']);
  });
});
