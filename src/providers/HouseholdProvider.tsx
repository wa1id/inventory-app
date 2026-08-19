import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react';

import type { Repositories } from '@/db/repositories';
import { pairWithHousehold, type HouseholdSession } from '@/services/household/client';
import { createHttpRepositories } from '@/services/household/httpRepositories';
import {
  clearHouseholdSession,
  loadHouseholdSession,
  saveHouseholdSession,
} from '@/services/household/session';

interface HouseholdContextValue {
  session: HouseholdSession | null;
  ready: boolean;
  repos: Repositories | null;
  pair: (bootstrapSecret: string, deviceName: string) => Promise<void>;
  disconnect: () => Promise<void>;
}

const HouseholdContext = createContext<HouseholdContextValue | null>(null);

export function HouseholdProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<HouseholdSession | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const stored = await loadHouseholdSession();
      if (!cancelled) {
        setSession(stored);
        setReady(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const repos = useMemo(() => (session ? createHttpRepositories(session) : null), [session]);

  const pair = useCallback(async (bootstrapSecret: string, deviceName: string) => {
    const next = await pairWithHousehold({ bootstrapSecret, deviceName });
    await saveHouseholdSession(next);
    setSession(next);
  }, []);

  const disconnect = useCallback(async () => {
    await clearHouseholdSession();
    setSession(null);
  }, []);

  const value = useMemo(
    () => ({ session, ready, repos, pair, disconnect }),
    [session, ready, repos, pair, disconnect],
  );

  return <HouseholdContext.Provider value={value}>{children}</HouseholdContext.Provider>;
}

export function useHousehold(): HouseholdContextValue {
  const context = useContext(HouseholdContext);
  if (!context) {
    throw new Error('useHousehold must be used inside a HouseholdProvider');
  }
  return context;
}
