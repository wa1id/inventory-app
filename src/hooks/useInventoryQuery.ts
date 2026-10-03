import { useCallback, useEffect, useRef, useState } from 'react';
import { useFocusEffect, useIsFocused } from 'expo-router';

import { useRevision } from '@/providers/DatabaseProvider';

export interface QueryResult<T> {
  /** The latest result for this key, kept while a refresh runs or fails. */
  data: T | null;
  loading: boolean;
  /** What the latest read threw; describe it with `ErrorState` / `describeError`. */
  cause: unknown;
  /** The latest read failed but earlier data is still on screen. */
  refreshFailed: boolean;
  reload: () => void;
}

interface Settled<T> {
  /** Identifies the request this result belongs to. */
  token: number;
  /** The query key it was read for, so a failure keeps only this key's data. */
  key: string;
  data: T | null;
  /** The read threw (kept apart from `cause`, which may itself be `undefined`). */
  failed: boolean;
  cause: unknown;
}

/**
 * Runs a read against SQLite and re-runs it whenever the data could have
 * changed: on mount, on screen focus, and after any write bumps `revision`.
 *
 * This is what makes created, edited, moved, and deleted inventory show up
 * without restarting the app (issues #5, #13, #14).
 *
 * `key` identifies the query's inputs (for example `space:${id}`). It is a
 * string rather than a dependency array so the effect's dependencies stay
 * statically analyzable — a dynamic array cannot be checked by the React hooks
 * lint rules, and a stale one is a silent bug.
 *
 * `loading` is derived rather than stored: a request is in flight exactly when
 * the newest request token has not settled yet. That keeps every state update
 * inside an async callback, so no render cascade is triggered from the effect
 * body.
 *
 * Two refinements for a phone that reads over the network when paired:
 * - A failed refresh keeps what was already on screen for the same key, so a
 *   blip never turns a list into an error page ("lists keep their last data").
 * - Writes only refetch the screen in front. A screen in the background
 *   notices the new `revision` when it is focused again, so one quantity tap
 *   no longer re-reads every mounted screen over HTTP.
 */
export function useInventoryQuery<T>(run: () => Promise<T>, key: string): QueryResult<T> {
  const revision = useRevision();
  const isFocused = useIsFocused();
  const [localRevision, setLocalRevision] = useState(0);
  const [seenRevision, setSeenRevision] = useState(revision);
  const [settled, setSettled] = useState<Settled<T>>({
    token: -1,
    key,
    data: null,
    failed: false,
    cause: null,
  });

  // Derived state, as in `useSavedQuantity`: the revision this screen has
  // caught up with follows the global one only while the screen is focused.
  if (isFocused && seenRevision !== revision) {
    setSeenRevision(revision);
  }

  const requestToken = hashToken(key, seenRevision, localRevision);

  // The latest `run` closure, kept in a ref so redefining it on every render
  // does not by itself retrigger the query. Assigned in an effect rather than
  // during render; effects run in declaration order, so the query effect below
  // always sees the current closure.
  const runRef = useRef(run);
  useEffect(() => {
    runRef.current = run;
  });

  useEffect(() => {
    let cancelled = false;

    runRef
      .current()
      .then((result) => {
        if (cancelled) return;
        setSettled({ token: requestToken, key, data: result, failed: false, cause: null });
      })
      .catch((cause: unknown) => {
        if (cancelled) return;
        setSettled((previous) => ({
          token: requestToken,
          key,
          data: previous.key === key ? previous.data : null,
          failed: true,
          cause,
        }));
      });

    return () => {
      cancelled = true;
    };
    // `key` is already folded into `requestToken`; listing it changes nothing.
  }, [requestToken, key]);

  // Re-read on focus so returning from a child screen shows fresh totals.
  useFocusEffect(
    useCallback(() => {
      setLocalRevision((value) => value + 1);
    }, []),
  );

  const reload = useCallback(() => setLocalRevision((value) => value + 1), []);

  const current = settled.token === requestToken;
  const failed = current && settled.failed;

  return {
    data: settled.data,
    cause: failed ? settled.cause : null,
    refreshFailed: failed && settled.data !== null,
    loading: !current,
    reload,
  };
}

/** Stable numeric identity for a (key, revision, localRevision) triple. */
function hashToken(key: string, revision: number, localRevision: number): number {
  let hash = 2166136261;
  const input = `${key}|${revision}|${localRevision}`;
  for (let i = 0; i < input.length; i += 1) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}
