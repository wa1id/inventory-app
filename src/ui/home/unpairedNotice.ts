import { useCallback, useEffect, useState } from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage';

const DISMISSED_KEY = 'notice.unpaired.dismissed.v1';

/**
 * Home's "This phone keeps its own inventory" notice, for a phone that has
 * not joined the household. It keeps her phone from quietly growing an
 * inventory of its own, and "Not now" puts it away for good on this phone.
 *
 * Hidden until storage has answered, so it never flashes up and away. If
 * storage cannot be read the notice shows, and "Not now" still hides it for
 * as long as the app is open.
 */
export function useUnpairedNotice(paired: boolean): { visible: boolean; dismiss: () => void } {
  // null: storage has not answered yet.
  const [dismissed, setDismissed] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    AsyncStorage.getItem(DISMISSED_KEY).then(
      (stored) => {
        if (!cancelled) setDismissed((current) => current ?? stored === '1');
      },
      () => {
        if (!cancelled) setDismissed((current) => current ?? false);
      },
    );
    return () => {
      cancelled = true;
    };
  }, []);

  const dismiss = useCallback(() => {
    setDismissed(true);
    AsyncStorage.setItem(DISMISSED_KEY, '1').catch(() => {
      // Only this phone forgets the choice; the notice comes back next launch.
    });
  }, []);

  return { visible: !paired && dismissed === false, dismiss };
}
