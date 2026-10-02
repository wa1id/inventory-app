import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import { AppState, type AppStateStatus } from 'react-native';

import { useDatabase } from '@/providers/DatabaseProvider';
import { useHousehold } from '@/providers/HouseholdProvider';
import { householdFetch, onHouseholdReachability } from '@/services/household/client';
import { markJoinedBefore } from '@/services/household/importOffer';
import { delay } from '@/ui/motion';

/**
 * - `local`: not part of a household; nothing to reach.
 * - `online`: the home server answered the last request.
 * - `unsure`: a request failed less than 2.5 s ago; probably a blip.
 * - `offline`: requests have been failing for 2.5 s.
 * - `revoked`: the server no longer accepts this phone (removed on another phone).
 */
export type ConnectionState = 'local' | 'online' | 'unsure' | 'offline' | 'revoked';

type PairedState = Exclude<ConnectionState, 'local'>;

interface ConnectionContextValue {
  state: ConnectionState;
  /** Asks the home server now and re-reads every list on screen. */
  retry: () => void;
}

const ConnectionContext = createContext<ConnectionContextValue | null>(null);

/** While offline, how often the home server is asked whether it is back. */
const HEALTH_PING_MS = 10_000;
const HEALTH_TIMEOUT_MS = 5_000;
/** Coming back to the app re-reads lists at most this often. */
const RESUME_REFRESH_MS = 5_000;

/**
 * What the phone knows about its connection to the home server, from the
 * requests it is making anyway (every household request reports through
 * `onHouseholdReachability`).
 *
 * Calm on purpose: a failure first makes the state `unsure`, and only after
 * 2.5 s without a success does it become `offline`, so brief blips never show
 * a banner. While offline it asks the unauthenticated health endpoint every
 * 10 s, and the first answer refreshes everything. A 401 means this phone was
 * removed on another phone; that sticks until the session changes. Coming back
 * to the app re-reads lists, so changes made on the other phone show up (#47).
 */
export function ConnectionProvider({ children }: { children: ReactNode }) {
  const { session } = useHousehold();
  const { invalidate } = useDatabase();
  const sessionKey = session ? `${session.origin}|${session.token}` : null;
  const origin = session?.origin ?? null;

  const [tracked, setTracked] = useState<{ key: string | null; state: PairedState }>({
    key: sessionKey,
    state: 'online',
  });
  const [appState, setAppState] = useState<AppStateStatus>(AppState.currentState);

  // A new session (joined, rejoined, left) starts from a clean slate.
  if (tracked.key !== sessionKey) {
    setTracked({ key: sessionKey, state: 'online' });
  }

  const state: ConnectionState = session ? tracked.state : 'local';

  const stateRef = useRef(state);
  useEffect(() => {
    stateRef.current = state;
  });

  useEffect(() => {
    if (!sessionKey) return;
    void markJoinedBefore();

    // The state as this subscription last set it: requests can settle twice
    // before React re-renders, so the rendered state would be a step behind.
    let current: PairedState = stateRef.current === 'local' ? 'online' : stateRef.current;
    let offlineTimer: ReturnType<typeof setTimeout> | null = null;
    const set = (next: PairedState) => {
      if (current === 'revoked' || current === next) return;
      current = next;
      setTracked((previous) =>
        previous.key === sessionKey ? { key: sessionKey, state: next } : previous,
      );
    };
    const cancelTimer = () => {
      if (offlineTimer) clearTimeout(offlineTimer);
      offlineTimer = null;
    };

    const unsubscribe = onHouseholdReachability((reachability) => {
      if (reachability === 'unauthorized') {
        cancelTimer();
        set('revoked');
        return;
      }
      if (reachability === 'ok') {
        cancelTimer();
        const wasOffline = current === 'offline';
        set('online');
        // Whatever failed while offline is read again now that it can be.
        if (wasOffline && current === 'online') invalidate();
        return;
      }
      if (current !== 'online' || offlineTimer) return;
      set('unsure');
      offlineTimer = setTimeout(() => {
        offlineTimer = null;
        set('offline');
      }, delay.reconnect);
    });

    return () => {
      unsubscribe();
      cancelTimer();
    };
  }, [invalidate, sessionKey]);

  const ping = useCallback(() => {
    if (!origin) return;
    // The result does not matter here: the request reports reachability itself.
    householdFetch({ origin, path: '/v1/health', timeoutMs: HEALTH_TIMEOUT_MS }).catch(
      () => undefined,
    );
  }, [origin]);

  useEffect(() => {
    const subscription = AppState.addEventListener('change', setAppState);
    return () => subscription.remove();
  }, []);

  const lastResumeRef = useRef(0);
  useEffect(() => {
    if (appState !== 'active' || !sessionKey) return;
    const now = Date.now();
    if (now - lastResumeRef.current < RESUME_REFRESH_MS) return;
    // The first time this runs is app start, where the screens read anyway.
    const first = lastResumeRef.current === 0;
    lastResumeRef.current = now;
    if (!first) invalidate();
  }, [appState, invalidate, sessionKey]);

  const offline = state === 'offline';
  useEffect(() => {
    if (!offline || appState !== 'active') return;
    const timer = setInterval(ping, HEALTH_PING_MS);
    return () => clearInterval(timer);
  }, [appState, offline, ping]);

  const retry = useCallback(() => {
    ping();
    invalidate();
  }, [invalidate, ping]);

  const value = useMemo(() => ({ state, retry }), [state, retry]);

  return <ConnectionContext.Provider value={value}>{children}</ConnectionContext.Provider>;
}

export function useConnection(): ConnectionContextValue {
  const context = useContext(ConnectionContext);
  if (!context) {
    throw new Error('useConnection must be used inside a ConnectionProvider');
  }
  return context;
}
