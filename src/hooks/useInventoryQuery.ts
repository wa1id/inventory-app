import { useCallback, useEffect, useRef, useState } from 'react';
import { useFocusEffect } from 'expo-router';

import { useDatabase } from '@/providers/DatabaseProvider';

export interface QueryResult<T> {
  data: T | null;
  loading: boolean;
  error: string | null;
  reload: () => void;
}

interface Settled<T> {
  /** Identifies the request this result belongs to. */
  token: number;
  data: T | null;
  error: string | null;
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
 */
export function useInventoryQuery<T>(run: () => Promise<T>, key: string): QueryResult<T> {
  const { revision } = useDatabase();
  const [localRevision, setLocalRevision] = useState(0);
  const [settled, setSettled] = useState<Settled<T>>({ token: -1, data: null, error: null });

  const requestToken = hashToken(key, revision, localRevision);

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
        setSettled({ token: requestToken, data: result, error: null });
      })
      .catch((cause: unknown) => {
        if (cancelled) return;
        setSettled({
          token: requestToken,
          data: null,
          error: cause instanceof Error ? cause.message : 'Could not read your inventory.',
        });
      });

    return () => {
      cancelled = true;
    };
  }, [requestToken]);

  // Re-read on focus so returning from a child screen shows fresh totals.
  useFocusEffect(
    useCallback(() => {
      setLocalRevision((value) => value + 1);
    }, []),
  );

  const reload = useCallback(() => setLocalRevision((value) => value + 1), []);

  return {
    data: settled.data,
    error: settled.token === requestToken ? settled.error : null,
    loading: settled.token !== requestToken,
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
