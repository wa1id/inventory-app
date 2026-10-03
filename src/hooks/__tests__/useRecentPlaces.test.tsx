import { act, create } from 'react-test-renderer';

import { useRecentPlaces } from '@/hooks/useRecentPlaces';
import { rememberPlace } from '@/services/places/recentPlaces';

const mockPreferences = new Map<string, string>([['places.recent.v1', '["a","b","c"]']]);

jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: async (key: string) => mockPreferences.get(key) ?? null,
    setItem: async (key: string, value: string) => {
      mockPreferences.set(key, value);
    },
  },
}));

/** A screen with a picker: renders nothing, records what the hook returned. */
function mountPicker() {
  const seen: { current: readonly string[] | null } = { current: null };
  function Picker() {
    seen.current = useRecentPlaces();
    return null;
  }
  act(() => {
    create(<Picker />);
  });
  return seen;
}

// One test, in order: the list is read from storage once per app run.
describe('useRecentPlaces', () => {
  it('takes the stored list, then holds it while the screen stays open', async () => {
    const open = mountPicker();
    await act(async () => {});
    expect(open.current).toEqual(['a', 'b', 'c']);

    // The pick that remembers "b" is the one that closes this screen: its
    // rows must not change places on the way out.
    await act(async () => {
      await rememberPlace('b');
    });
    expect(open.current).toEqual(['a', 'b', 'c']);

    expect(mountPicker().current).toEqual(['b', 'a', 'c']);
  });
});
