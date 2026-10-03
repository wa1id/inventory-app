import { useEffect, useState, useSyncExternalStore } from 'react';

import {
  peekRecentPlaces,
  readRecentPlaces,
  subscribeRecentPlaces,
} from '@/services/places/recentPlaces';

const EMPTY: readonly string[] = [];

/**
 * Container ids this phone used last, most recent first, in the order they
 * had when the screen opened: a place remembered after a move shows up in the
 * next picker, while the open one keeps its rows where they are.
 *
 * The pick that remembers a place is also the one that closes the screen, and
 * rows that change places in a closing screen break the Android renderer
 * ("addViewAt: … already has a parent"). Held still, the row just tapped also
 * stays under the finger while the sheet slides away.
 *
 * Callers filter the ids to containers that still exist; a deleted container
 * just drops out of the list they render.
 */
export function useRecentPlaces(): readonly string[] {
  const live = useSyncExternalStore(subscribeRecentPlaces, peekRecentPlaces, () => null);
  // Held from the first answer. Before storage has been read the list is
  // unknown rather than empty, so that first read still comes in.
  const [held, setHeld] = useState(live);
  if (held === null && live !== null) setHeld(live);

  useEffect(() => {
    void readRecentPlaces();
  }, []);

  return held ?? live ?? EMPTY;
}
