import { useCallback, useEffect, useRef } from 'react';
import { useFocusEffect, useNavigation, type NativeStackNavigationProp } from 'expo-router';
import type { ParamListBase } from 'expo-router/react-navigation';

interface SearchFocusRequest {
  /** A pushed screen or a sheet is being closed on the way to Home. */
  afterTransition: boolean;
}

// One-shot and in memory, rather than a `?focus=` route param that would stay
// in Home's params and pull the keyboard up again on every later visit.
let request: SearchFocusRequest | null = null;

/** Most a closing screen's animation is waited for before focusing anyway. */
const TRANSITION_FALLBACK_MS = 600;

/**
 * Asks Home to focus its search field the next time it gains focus.
 *
 * Pass `afterTransition` when screens are being closed to get there: focusing
 * a field while a sheet is still sliding away makes the keyboard fight the
 * animation, so Home waits for it to finish.
 */
export function requestSearchFocus(options: { afterTransition?: boolean } = {}): void {
  request = { afterTransition: options.afterTransition ?? false };
}

/** Takes the pending request, if any; a request is only ever answered once. */
export function consumeSearchFocusRequest(): SearchFocusRequest | null {
  const taken = request;
  request = null;
  return taken;
}

/**
 * Runs `onRequest` (Home focusing its search field) when the screen gains
 * focus with a request pending. When the request came with closing screens,
 * it waits for the root stack's transition to end first.
 */
export function useSearchFocusRequest(onRequest: () => void): void {
  const navigation = useNavigation();
  const onRequestRef = useRef(onRequest);
  useEffect(() => {
    onRequestRef.current = onRequest;
  });

  useFocusEffect(
    useCallback(() => {
      const taken = consumeSearchFocusRequest();
      if (!taken) return;

      let done = false;
      const run = () => {
        if (done) return;
        done = true;
        onRequestRef.current();
      };

      if (!taken.afterTransition) {
        run();
        return;
      }

      // The tab screen's parent is the `(tabs)` route in the root stack, which
      // reports the end of the pop that revealed it.
      const stack = navigation.getParent<NativeStackNavigationProp<ParamListBase> | undefined>();
      const unsubscribe = stack?.addListener('transitionEnd', (event) => {
        if (!event.data.closing) run();
      });
      const timer = setTimeout(run, TRANSITION_FALLBACK_MS);
      return () => {
        done = true;
        unsubscribe?.();
        clearTimeout(timer);
      };
    }, [navigation]),
  );
}
