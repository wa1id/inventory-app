import { useSyncExternalStore } from 'react';
import { AccessibilityInfo, Easing, LayoutAnimation } from 'react-native';

/** Motion lengths in ms. All become 0 under reduced motion. */
export const duration = {
  press: 100,
  toastIn: 160,
  toastOut: 120,
  expand: 180,
  stepSwap: 180,
  reticleLock: 250,
  focusSpot: 700,
  shutterFlash: 120,
} as const;

/**
 * Waits in ms. These are timing, not motion, so reduced motion leaves them
 * alone: a skeleton still waits 180 ms so fast reads never flash.
 */
export const delay = {
  skeleton: 180,
  spinner: 150,
  bootCaption: 400,
  reconnect: 2500,
  searchDebounce: 200,
  searchSkeleton: 600,
  toast: 5000,
  toastWithAction: 9000,
  stepRepeat: 400,
  stepRepeatEvery: 80,
} as const;

export const easing = {
  settle: Easing.bezier(0.2, 0.8, 0.2, 1),
  out: Easing.out(Easing.cubic),
  exit: Easing.bezier(0.4, 0, 1, 1),
};

/** A motion length, or 0 when the person asked for less motion. */
export function motionMs(ms: number, reduced: boolean): number {
  return reduced ? 0 : ms;
}

// One subscription for the whole app rather than one per row: a list of 40
// rows that each animate their own expansion would otherwise hold 40.
let reducedMotion = false;
let listening = false;
const listeners = new Set<() => void>();

function setReducedMotion(value: boolean) {
  if (value === reducedMotion) return;
  reducedMotion = value;
  listeners.forEach((listener) => listener());
}

function listen() {
  if (listening) return;
  listening = true;
  AccessibilityInfo.isReduceMotionEnabled()
    .then(setReducedMotion)
    .catch(() => undefined);
  AccessibilityInfo.addEventListener('reduceMotionChanged', setReducedMotion);
}

function subscribe(listener: () => void): () => void {
  listen();
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** The system "Reduce motion" setting, kept live. */
export function useReducedMotion(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => reducedMotion,
    () => false,
  );
}

/**
 * Cross-fades the next layout change (a chip expanding, a row leaving a list).
 *
 * Call immediately before the state change. Skipped entirely under reduced
 * motion, so the change is instant rather than a zero-length animation.
 */
export function animateNextLayout(): void {
  listen();
  if (reducedMotion) return;
  LayoutAnimation.configureNext(
    LayoutAnimation.create(duration.expand, 'easeInEaseOut', 'opacity'),
  );
}
