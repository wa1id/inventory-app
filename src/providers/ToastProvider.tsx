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
import { AccessibilityInfo, Platform } from 'react-native';
import { useIsFocused } from 'expo-router';

import { strings } from '@/i18n/strings';
import { delay, duration } from '@/ui/motion';

export interface ToastAction {
  label: string;
  onPress: () => void;
  /** Item-specific where it helps: "Undo moving Cordless drill". */
  accessibilityLabel?: string;
}

export interface ToastOptions {
  message: string;
  tone?: 'info' | 'error';
  action?: ToastAction;
  /** Overrides the default 5 s (9 s with an action). */
  duration?: number;
}

export interface ToastRecord extends ToastOptions {
  id: string;
  tone: 'info' | 'error';
  shownAt: number;
}

interface ToastApi {
  /** Shows a toast and returns its id. */
  show: (options: ToastOptions) => string;
  dismiss: (id: string) => void;
}

interface ToastContextValue extends ToastApi {
  /** Registers bottom chrome the toast has to clear; returns the unregister function. */
  registerChrome: (height: number) => () => void;
}

/** What the host needs to draw the toast. */
export interface ToastHostState {
  current: ToastRecord | null;
  /** The exit animation is running; the toast goes once it ends. */
  leaving: boolean;
  /** The focused screen's tab bar or bottom bar, if it registered one. */
  chromeHeight: number | null;
  pause: () => void;
  resume: () => void;
  dismiss: (id: string) => void;
}

const ToastContext = createContext<ToastContextValue | null>(null);
const ToastHostContext = createContext<ToastHostState | null>(null);

/** An error is never replaced before it has been on screen this long. */
const ERROR_HOLD_MS = 1500;

let nextToastId = 0;

/**
 * Toasts for writes that finished somewhere the person is no longer looking:
 * "Moved to Tool chest (Garage)" with Undo after a move sheet closes, or a
 * quantity that did not save in a row of a long list.
 *
 * One toast at a time. A new one replaces the current one, except that an
 * error stays up for at least 1.5 s and the newcomer waits behind it, so a
 * failure is never wiped by the success that follows it. Toasts last 5 s, 9 s
 * with an action, twice that with a screen reader running, and stand still
 * while a finger is on them. `OverlayHost` draws them, above native sheets.
 */
export function ToastProvider({ children }: { children: ReactNode }) {
  const [current, setCurrent] = useState<ToastRecord | null>(null);
  const [leaving, setLeaving] = useState(false);
  const [chrome, setChrome] = useState<{ token: number; height: number }[]>([]);

  // Mirrors and timers for the callbacks; never read while rendering.
  const currentRef = useRef<ToastRecord | null>(null);
  const pendingRef = useRef<ToastRecord | null>(null);
  const lifeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const leaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lifeRef = useRef({ remaining: 0, startedAt: 0 });
  const screenReaderRef = useRef(false);
  const chromeTokenRef = useRef(0);

  useEffect(() => {
    let active = true;
    AccessibilityInfo.isScreenReaderEnabled()
      .then((enabled) => {
        if (active) screenReaderRef.current = enabled;
      })
      .catch(() => undefined);
    const subscription = AccessibilityInfo.addEventListener('screenReaderChanged', (enabled) => {
      screenReaderRef.current = enabled;
    });
    return () => {
      active = false;
      subscription.remove();
    };
  }, []);

  useEffect(
    () => () => {
      [lifeTimerRef, holdTimerRef, leaveTimerRef].forEach((timer) => {
        if (timer.current) clearTimeout(timer.current);
      });
    },
    [],
  );

  const clearTimer = useCallback((timer: { current: ReturnType<typeof setTimeout> | null }) => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;
  }, []);

  const remove = useCallback(
    (id: string) => {
      if (currentRef.current?.id !== id) return;
      clearTimer(leaveTimerRef);
      currentRef.current = null;
      setCurrent(null);
      setLeaving(false);
    },
    [clearTimer],
  );

  const leave = useCallback(
    (id: string) => {
      if (currentRef.current?.id !== id) return;
      clearTimer(lifeTimerRef);
      setLeaving(true);
      clearTimer(leaveTimerRef);
      leaveTimerRef.current = setTimeout(() => remove(id), duration.toastOut);
    },
    [clearTimer, remove],
  );

  const startLife = useCallback(
    (id: string, ms: number) => {
      clearTimer(lifeTimerRef);
      lifeRef.current = { remaining: ms, startedAt: Date.now() };
      lifeTimerRef.current = setTimeout(() => leave(id), ms);
    },
    [clearTimer, leave],
  );

  const present = useCallback(
    (record: ToastRecord) => {
      clearTimer(leaveTimerRef);
      const shown = { ...record, shownAt: Date.now() };
      currentRef.current = shown;
      setCurrent(shown);
      setLeaving(false);

      const base = record.duration ?? (record.action ? delay.toastWithAction : delay.toast);
      startLife(shown.id, screenReaderRef.current ? base * 2 : base);

      // Android reads the host's live region; iOS has to be told, queued so it
      // does not cut off whatever VoiceOver is saying.
      if (Platform.OS === 'ios') {
        const spoken = record.action
          ? `${record.message}, ${strings.a11y.availableAction(record.action.label)}`
          : record.message;
        AccessibilityInfo.announceForAccessibilityWithOptions(spoken, { queue: true });
      }
    },
    [clearTimer, startLife],
  );

  const show = useCallback(
    (options: ToastOptions) => {
      nextToastId += 1;
      const record: ToastRecord = {
        ...options,
        id: `toast-${nextToastId}`,
        tone: options.tone ?? 'info',
        shownAt: Date.now(),
      };
      const shown = currentRef.current;
      const heldFor = shown ? Date.now() - shown.shownAt : Infinity;

      if (shown?.tone === 'error' && heldFor < ERROR_HOLD_MS) {
        // Wait behind the error. Of several waiting, the newest wins, but an
        // error is never dropped for an info toast.
        const waiting = pendingRef.current;
        if (!(waiting?.tone === 'error' && record.tone === 'info')) pendingRef.current = record;
        if (!holdTimerRef.current) {
          holdTimerRef.current = setTimeout(() => {
            holdTimerRef.current = null;
            const next = pendingRef.current;
            pendingRef.current = null;
            if (next) present(next);
          }, ERROR_HOLD_MS - heldFor);
        }
        return record.id;
      }

      present(record);
      return record.id;
    },
    [present],
  );

  const dismiss = useCallback(
    (id: string) => {
      if (pendingRef.current?.id === id) pendingRef.current = null;
      leave(id);
    },
    [leave],
  );

  const pause = useCallback(() => {
    if (!lifeTimerRef.current) return;
    clearTimer(lifeTimerRef);
    const { remaining, startedAt } = lifeRef.current;
    lifeRef.current = {
      remaining: Math.max(0, remaining - (Date.now() - startedAt)),
      startedAt: 0,
    };
  }, [clearTimer]);

  const resume = useCallback(() => {
    const shown = currentRef.current;
    if (!shown || lifeTimerRef.current || lifeRef.current.startedAt !== 0) return;
    // Never gone the instant a finger lifts: there is time to read or press.
    startLife(shown.id, Math.max(lifeRef.current.remaining, delay.toast / 2));
  }, [startLife]);

  const registerChrome = useCallback((height: number) => {
    chromeTokenRef.current += 1;
    const token = chromeTokenRef.current;
    setChrome((list) => [...list, { token, height }]);
    return () => setChrome((list) => list.filter((entry) => entry.token !== token));
  }, []);

  const api = useMemo(() => ({ show, dismiss, registerChrome }), [show, dismiss, registerChrome]);

  const chromeHeight = chrome.length > 0 ? (chrome[chrome.length - 1]?.height ?? null) : null;
  const host = useMemo(
    () => ({ current, leaving, chromeHeight, pause, resume, dismiss }),
    [current, leaving, chromeHeight, pause, resume, dismiss],
  );

  return (
    <ToastContext.Provider value={api}>
      <ToastHostContext.Provider value={host}>{children}</ToastHostContext.Provider>
    </ToastContext.Provider>
  );
}

export function useToast(): ToastApi {
  const context = useContext(ToastContext);
  if (!context) {
    throw new Error('useToast must be used inside a ToastProvider');
  }
  return context;
}

/** For `ToastHost` only. */
export function useToastHostState(): ToastHostState {
  const context = useContext(ToastHostContext);
  if (!context) {
    throw new Error('useToastHostState must be used inside a ToastProvider');
  }
  return context;
}

/**
 * Tells the toast how tall the bottom chrome (tab bar, bottom bar) of the
 * focused screen is, so it floats just above it rather than over the buttons.
 * Outside a `ToastProvider` there is no toast to make room for, so it does
 * nothing.
 */
export function useBottomChrome(height: number): void {
  const context = useContext(ToastContext);
  const isFocused = useIsFocused();
  const register = context?.registerChrome;

  useEffect(() => {
    if (!register || !isFocused || height <= 0) return;
    return register(height);
  }, [height, isFocused, register]);
}
