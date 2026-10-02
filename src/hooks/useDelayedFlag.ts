import { useEffect, useState } from 'react';

import { delay } from '@/ui/motion';

/**
 * True only after `active` has stayed true for `ms`.
 *
 * Fast reads finish before a skeleton or spinner would appear, so they never
 * flash one. The flag is only ever set from the timer callback, and `false`
 * is derived rather than stored, so nothing calls setState in an effect body.
 */
export function useDelayedFlag(active: boolean, ms: number = delay.skeleton): boolean {
  const [elapsed, setElapsed] = useState(false);

  useEffect(() => {
    if (!active) return;
    const timer = setTimeout(() => setElapsed(true), ms);
    return () => {
      clearTimeout(timer);
      setElapsed(false);
    };
  }, [active, ms]);

  return active && elapsed;
}
