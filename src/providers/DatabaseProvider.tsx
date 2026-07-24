import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';

import { openExpoDatabase } from '@/db/expoDatabase';
import { initializeRepositories } from '@/db/repositories';
import type { Repositories } from '@/db/repositories';
import { logEvent } from '@/services/telemetry';

type DatabaseState =
  | { status: 'loading' }
  | { status: 'ready'; repos: Repositories }
  | { status: 'error'; message: string };

interface DatabaseContextValue {
  state: DatabaseState;
  /**
   * Bumped after every write. Screens read it as a dependency so lists refresh
   * from SQLite immediately — the database stays the single source of truth
   * instead of a mirrored in-memory cache that could drift.
   */
  revision: number;
  invalidate: () => void;
  retry: () => void;
}

const DatabaseContext = createContext<DatabaseContextValue | null>(null);

export function DatabaseProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<DatabaseState>({ status: 'loading' });
  const [revision, setRevision] = useState(0);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      const startedAt = Date.now();
      try {
        const db = await openExpoDatabase();
        const repos = await initializeRepositories(db);
        if (cancelled) return;
        logEvent('database_ready', { durationMs: Date.now() - startedAt });
        setState({ status: 'ready', repos });
      } catch (error) {
        if (cancelled) return;
        logEvent('database_open_failed', { durationMs: Date.now() - startedAt });
        setState({
          status: 'error',
          message:
            error instanceof Error ? error.message : 'The inventory database could not be opened.',
        });
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [attempt]);

  const invalidate = useCallback(() => setRevision((value) => value + 1), []);
  const retry = useCallback(() => {
    setState({ status: 'loading' });
    setAttempt((value) => value + 1);
  }, []);

  const value = useMemo(
    () => ({ state, revision, invalidate, retry }),
    [state, revision, invalidate, retry],
  );

  return <DatabaseContext.Provider value={value}>{children}</DatabaseContext.Provider>;
}

export function useDatabase(): DatabaseContextValue {
  const context = useContext(DatabaseContext);
  if (!context) {
    throw new Error('useDatabase must be used inside a DatabaseProvider');
  }
  return context;
}

/**
 * Repositories for screens rendered below the readiness gate in the root
 * layout, which is the only place they are mounted.
 */
export function useRepositories(): Repositories {
  const { state } = useDatabase();
  if (state.status !== 'ready') {
    throw new Error('Repositories are not available until the database is ready');
  }
  return state.repos;
}
