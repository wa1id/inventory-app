import { useEffect, useState } from 'react';
import { useIsFocused } from 'expo-router';

/**
 * The current time, refreshed every `intervalMs` while the screen is focused,
 * for copy that ages ("Last backup 5 minutes ago", "Added just now").
 *
 * A screen in the background does not tick; it catches up as soon as it is
 * focused again.
 */
export function useNow(intervalMs: number = 60_000): number {
  const isFocused = useIsFocused();
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (!isFocused) return;
    const tick = () => setNow(Date.now());
    // Catch up straight away after coming back, then keep ticking.
    const first = setTimeout(tick, 0);
    const timer = setInterval(tick, intervalMs);
    return () => {
      clearTimeout(first);
      clearInterval(timer);
    };
  }, [intervalMs, isFocused]);

  return now;
}
