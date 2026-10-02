import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';
import { useNavigation } from 'expo-router';
import { usePreventRemove } from 'expo-router/react-navigation';

import { strings } from '@/i18n/strings';
import { confirm } from '@/ui/confirm';

/**
 * Asks before a form with unsaved typing closes: Cancel, Android back, the
 * header close and, on iOS, the sheet's swipe-down, which is switched off
 * while the form is dirty so the sheet resists instead of vanishing.
 *
 * Pass `saving` while the save itself is closing the form, so a successful
 * save never asks "Discard your changes?". `onDiscard` runs before the screen
 * closes (for example to drop a photo nobody kept). Used by Edit details and
 * the space and container forms; the Add sheet keeps a draft instead.
 */
export function useDirtyGuard(
  dirty: boolean,
  options: { title?: string; saving?: boolean; onDiscard?: () => void } = {},
): void {
  const navigation = useNavigation();
  const guarded = dirty && !options.saving;

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
    navigation.setOptions({ gestureEnabled: !guarded });
  }, [guarded, navigation]);
}
