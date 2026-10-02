import { useEffect, useState } from 'react';
import { Keyboard, Platform, type KeyboardEvent } from 'react-native';

/**
 * The software keyboard's height and visibility, from keyboard events.
 *
 * Forms rely on `KeyboardAvoidingView`; this is the fallback for where that
 * misbehaves (an iOS page sheet's offset, Android edge-to-edge; spec R6): a
 * bottom bar can lift itself by `height`. iOS reports before the keyboard
 * moves, so the change is scheduled into the keyboard's own animation; Android
 * only reports afterwards.
 */
export function useKeyboardInset(): { height: number; visible: boolean } {
  const [state, setState] = useState({ height: 0, visible: false });

  useEffect(() => {
    const ios = Platform.OS === 'ios';
    const show = (event: KeyboardEvent) => {
      if (ios) Keyboard.scheduleLayoutAnimation(event);
      setState({ height: event.endCoordinates.height, visible: true });
    };
    const hide = (event: KeyboardEvent) => {
      if (ios) Keyboard.scheduleLayoutAnimation(event);
      setState({ height: 0, visible: false });
    };
    const subscriptions = [
      Keyboard.addListener(ios ? 'keyboardWillShow' : 'keyboardDidShow', show),
      Keyboard.addListener(ios ? 'keyboardWillHide' : 'keyboardDidHide', hide),
    ];
    return () => subscriptions.forEach((subscription) => subscription.remove());
  }, []);

  return state;
}
