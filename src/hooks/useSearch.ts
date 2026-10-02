import { useCallback, useEffect, useRef, useState } from 'react';
import { useFocusEffect, useIsFocused } from 'expo-router';

import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import type { SearchResults } from '@/repositories/search';
import { logEvent } from '@/services/telemetry';
import { rememberCategories } from '@/ui/categoryMemory';
import { delay } from '@/ui/motion';

export interface SearchState {
  /** The query `results` belong to: '' until a search has finished. */
  settledQuery: string;
  /**
   * Results for `settledQuery`. Kept while that query runs again and when a
   * re-run fails, so a blip never empties the list.
   */
  results: SearchResults | null;
  /** Why the latest run of the current query failed; null while it runs or when it did not. */
  cause: unknown;
  /**
   * The results do not belong to what is in the field yet: she is typing, or
   * the new query is in flight. Older results must not look current.
   */
  pending: boolean;
  /** The current query is running again (Home refocused, a write elsewhere, Try again). */
  refreshing: boolean;
  /** Runs the current query again; "Try again" after a failure (B2). */
  retry: () => void;
}

interface Settled {
  query: string;
  /** Which run of that query answered: the revision and nonce it was read at. */
  run: string;
  results: SearchResults | null;
  cause: unknown;
}

const NOTHING_SETTLED: Settled = { query: '', run: '', results: null, cause: null };

/**
 * Home's search: what she types, matched against names, places and the codes
 * written on labels.
 *
 * - A new query waits for a 200 ms pause in typing; the same query run again
 *   starts at once.
 * - Results always belong to a query (`settledQuery`), so `pending` is derived
 *   rather than stored, and results for an older query are never shown as the
 *   answer to the current one (screens-home §10.11).
 * - The current query runs again when Home is focused and after any write
 *   (`revision`), so an item edited, moved or deleted elsewhere is never
 *   shown as it was (B3). Like `useInventoryQuery`, a write only re-runs the
 *   search while Home is in front; Home catches up when it is focused again.
 * - `search_performed` is logged once per settled query with counts only;
 *   the text she typed is never logged.
 */
export function useSearch(query: string): SearchState {
  const repos = useRepositories();
  const { revision } = useDatabase();
  const isFocused = useIsFocused();
  const trimmed = query.trim();

  // Derived state, as in `useInventoryQuery`: the revision this search has
  // caught up with follows the global one only while Home is focused.
  const [seenRevision, setSeenRevision] = useState(revision);
  if (isFocused && seenRevision !== revision) {
    setSeenRevision(revision);
  }
  // Bumped on focus and by `retry`. A plain counter, so "Try again" always
  // changes something (the old retry re-set the same string and did nothing, B2).
  const [nonce, setNonce] = useState(0);
  const run = `${seenRevision}|${nonce}`;

  const [settled, setSettled] = useState<Settled>(NOTHING_SETTLED);

  // Read by the search effect without making it re-run: the repositories
  // object, and the query the results on screen belong to (for the debounce).
  const latest = useRef({ repos, settledQuery: settled.query });
  useEffect(() => {
    latest.current = { repos, settledQuery: settled.query };
  });
  const loggedQuery = useRef('');

  useEffect(() => {
    if (!trimmed) {
      // Searching the same words again later is a new search.
      loggedQuery.current = '';
      return;
    }

    let cancelled = false;
    const wait = trimmed === latest.current.settledQuery ? 0 : delay.searchDebounce;

    const timer = setTimeout(() => {
      latest.current.repos.search.search(trimmed).then(
        (found) => {
          if (cancelled) return;
          setSettled({ query: trimmed, run, results: found, cause: null });
          rememberCategories(found.items);
          if (loggedQuery.current !== trimmed) {
            loggedQuery.current = trimmed;
            logEvent('search_performed', {
              termCount: found.terms.length,
              resultCount: found.items.length + found.locations.length,
              queryLength: trimmed.length,
            });
          }
        },
        (cause: unknown) => {
          if (cancelled) return;
          setSettled((previous) => ({
            query: trimmed,
            run,
            results: previous.query === trimmed ? previous.results : null,
            cause,
          }));
        },
      );
    }, wait);

    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [trimmed, run]);

  useFocusEffect(
    useCallback(() => {
      setNonce((value) => value + 1);
    }, []),
  );

  const retry = useCallback(() => setNonce((value) => value + 1), []);

  const current = trimmed !== '' && settled.query === trimmed;
  const answered = current && settled.run === run;

  return {
    settledQuery: settled.query,
    results: settled.results,
    cause: answered ? settled.cause : null,
    pending: trimmed !== '' && !current,
    refreshing: current && !answered,
    retry,
  };
}
