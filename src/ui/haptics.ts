import { Platform } from 'react-native';
import * as Haptics from 'expo-haptics';

/**
 * One place for every haptic, so the same moment always feels the same.
 *
 * Every call is fire-and-forget: a haptic that fails (simulator, power saving)
 * must never reject into the caller, and the web has no engine at all.
 */
function play(task: () => Promise<void>): void {
  if (Platform.OS === 'web') return;
  void task().catch(() => undefined);
}

export const haptics = {
  /** Stepper ± tap (every 5th step during hold-repeat). */
  step: () => play(() => Haptics.selectionAsync()),
  /** Stepper reached 0, "None left": a heavier tick than a plain step. */
  reachedZero: () => play(() => Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light)),
  /** A choice changed: place, space, type, colour, icon, segment; search cleared. */
  choice: () => play(() => Haptics.selectionAsync()),
  /** Undo applied. */
  undo: () => play(() => Haptics.selectionAsync()),
  /** Add, Move, File, label linked, joined, QR recognised. */
  success: () => play(() => Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)),
  /** A conflict (409) shown to the person. */
  warning: () => play(() => Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning)),
  /** A failed write, an invalid QR, a quantity that did not save. */
  error: () => play(() => Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error)),
  /** Add block pressed; fast-mode shot returned. */
  tap: () => play(() => Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light)),
  /** Add block long-pressed (Quick Snap): distinct from a plain tap. */
  longPress: () => play(() => Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium)),
};
