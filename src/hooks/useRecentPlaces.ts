import { useEffect, useSyncExternalStore } from 'react';

import {
  peekRecentPlaces,
  readRecentPlaces,
  subscribeRecentPlaces,
} from '@/services/places/recentPlaces';

const EMPTY: readonly string[] = [];

/**
 * Container ids this phone used last, most recent first, kept live: a place
 * remembered after a move shows up in the next picker straight away.
 *
 * Callers filter the ids to containers that still exist; a deleted container
 * just drops out of the list they render.
 */
export function useRecentPlaces(): readonly string[] {
  const ids = useSyncExternalStore(
    subscribeRecentPlaces,
    () => peekRecentPlaces() ?? EMPTY,
    () => EMPTY,
  );

  useEffect(() => {
    void readRecentPlaces();
  }, []);

  return ids;
}
