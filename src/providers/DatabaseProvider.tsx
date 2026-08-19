import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import * as Crypto from 'expo-crypto';

import { configureRandomBytes } from '@/core/id';
import { openExpoDatabase } from '@/db/expoDatabase';
import { initializeRepositories } from '@/db/repositories';
import type { Repositories } from '@/db/repositories';
import { useHousehold } from '@/providers/HouseholdProvider';
import { withLocalShadow } from '@/services/household/shadow';
import { logEvent } from '@/services/telemetry';

// Installed at module load so capture/imageStore can call `newId` without
// going through this provider. The home server injects `node:crypto` instead.
configureRandomBytes((count) => Crypto.getRandomBytes(count));

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
  const household = useHousehold();
  if (state.status !== 'ready') {
    throw new Error('Repositories are not available until the database is ready');
  }
  if (household.session && household.repos) {
    return withLocalShadow(household.repos, state.repos);
  }
  return state.repos;
}
