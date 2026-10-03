import { useEffect, useRef } from 'react';
import { BackHandler, Platform } from 'react-native';
import { useNavigation } from 'expo-router';
import { usePreventRemove } from 'expo-router/react-navigation';

import { strings } from '@/i18n/strings';
import { useConnection } from '@/providers/ConnectionProvider';
import { confirm } from '@/ui/confirm';

/**
 * Asks before a form with unsaved typing closes: Cancel, Android back, the
 * header close and, on iOS, the sheet's swipe-down, which is switched off
 * while the form is dirty so the sheet resists instead of vanishing.
 *
 * Pass `saving` while a write is in flight. The sheet then stays put (no
 * swipe-down, Android back does nothing) and is not asked about, so a
 * successful save that closes the form never asks "Discard your changes?".
 * The header close still works then; the form checks it is still in front
 * before its own navigation after the write. `onDiscard` runs before the
 * screen closes (for example to drop a photo nobody kept). Used by Edit
 * details and the space and container forms; the Add sheet keeps a draft
 * instead.
 *
 * While the removed-phone layer is up there is nothing to keep editing, so
 * the layer closing every sheet is never asked about.
 */
export function useDirtyGuard(
  dirty: boolean,
  options: { title?: string; saving?: boolean; onDiscard?: () => void } = {},
): void {
  const navigation = useNavigation();
  const revoked = useConnection().state === 'revoked';
  const locked = options.saving === true;
  const guarded = dirty && !locked && !revoked;

  const optionsRef = useRef(options);
  useEffect(() => {
    optionsRef.current = options;
  });

  usePreventRemove(guarded, ({ data }) => {
    void confirm({
      title: optionsRef.current.title ?? strings.forms.discardTitle,
      body: strings.forms.discardBody,
      confirmLabel: strings.forms.discard,
      cancelLabel: strings.forms.keepEditing,
    }).then((discard) => {
      if (!discard) return;
      optionsRef.current.onDiscard?.();
      navigation.dispatch(data.action);
    });
  });

  useEffect(() => {
    if (Platform.OS !== 'ios') return;
    navigation.setOptions({ gestureEnabled: !(dirty || locked) });
  }, [dirty, locked, navigation]);

  // Mid-save, Android back would close the sheet under the write (iOS: the
  // swipe-down above), and the save's own navigation would then pop whatever
  // is in front by then.
  useEffect(() => {
    if (!locked) return;
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => true);
    return () => subscription.remove();
  }, [locked]);
}
