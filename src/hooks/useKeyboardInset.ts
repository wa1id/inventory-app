import { useEffect, useState } from 'react';
import { Keyboard, Platform, type KeyboardEvent } from 'react-native';

import { animateWithKeyboard } from '@/ui/motion';

/**
 * Whether the software keyboard is up, from keyboard events.
 *
 * `BottomBar` reads `visible` to drop the home-indicator inset on both
 * platforms; `TabBar` reads it to hide itself on Android only, so it passes
 * `enabled: false` on iOS.
 *
 * iOS reports before the keyboard moves, so each subscribed caller schedules
 * a global layout animation on the keyboard's curve (none under reduced
 * motion) for the next commit, whatever it is. Only components whose own
 * layout changes with the keyboard should subscribe there. Android only
 * reports afterwards.
 */
export function useKeyboardInset({ enabled = true }: { enabled?: boolean } = {}): {
  visible: boolean;
} {
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    if (!enabled) return;
    const ios = Platform.OS === 'ios';
    const show = (event: KeyboardEvent) => {
      if (ios) animateWithKeyboard(event);
      setVisible(true);
    };
    const hide = (event: KeyboardEvent) => {
      if (ios) animateWithKeyboard(event);
      setVisible(false);
    };
    const subscriptions = [
      Keyboard.addListener(ios ? 'keyboardWillShow' : 'keyboardDidShow', show),
      Keyboard.addListener(ios ? 'keyboardWillHide' : 'keyboardDidHide', hide),
    ];
    return () => subscriptions.forEach((subscription) => subscription.remove());
  }, [enabled]);

  return { visible };
}
