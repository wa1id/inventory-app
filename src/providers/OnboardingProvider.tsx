import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';

import { hasCompletedOnboarding, setOnboardingCompleted } from '@/services/onboarding';

type OnboardingStatus = 'loading' | 'pending' | 'completed';

interface OnboardingContextValue {
  status: OnboardingStatus;
  /** Marks onboarding done and updates the gate in the same tick. */
  complete: () => Promise<void>;
  /** Clears completion so the intro can be replayed from Settings. */
  replay: () => Promise<void>;
}

const OnboardingContext = createContext<OnboardingContextValue | null>(null);

/**
 * Owns onboarding completion for the whole app.
 *
 * This state has to be shared rather than read locally: the root layout gates
 * navigation on it, so if the onboarding screen finished by writing only to
 * storage, the gate would still hold the stale value and immediately redirect
 * back to step one.
 */
export function OnboardingProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<OnboardingStatus>('loading');

  useEffect(() => {
    hasCompletedOnboarding().then((seen) => setStatus(seen ? 'completed' : 'pending'));
  }, []);

  const complete = useCallback(async () => {
    setStatus('completed');
    await setOnboardingCompleted(true);
  }, []);

  const replay = useCallback(async () => {
    setStatus('pending');
    await setOnboardingCompleted(false);
  }, []);

  const value = useMemo(() => ({ status, complete, replay }), [status, complete, replay]);

  return <OnboardingContext.Provider value={value}>{children}</OnboardingContext.Provider>;
}

export function useOnboarding(): OnboardingContextValue {
  const context = useContext(OnboardingContext);
  if (!context) {
    throw new Error('useOnboarding must be used inside an OnboardingProvider');
  }
  return context;
}
