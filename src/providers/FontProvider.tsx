import { useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import { AccessibilityInfo, Platform } from 'react-native';
import { AtkinsonHyperlegibleNext_400Regular } from '@expo-google-fonts/atkinson-hyperlegible-next/400Regular';
import { AtkinsonHyperlegibleNext_500Medium } from '@expo-google-fonts/atkinson-hyperlegible-next/500Medium';
import { AtkinsonHyperlegibleNext_600SemiBold } from '@expo-google-fonts/atkinson-hyperlegible-next/600SemiBold';
import { AtkinsonHyperlegibleNext_700Bold } from '@expo-google-fonts/atkinson-hyperlegible-next/700Bold';
import { AtkinsonHyperlegibleNext_800ExtraBold } from '@expo-google-fonts/atkinson-hyperlegible-next/800ExtraBold';
import { isLoaded, loadAsync } from 'expo-font';

import { logError } from '@/services/telemetry';
import { FontContext } from '@/ui/fontContext';
import { FONT_FAMILY } from '@/ui/typography';

export { useBoldText, useFontsReady } from '@/ui/fontContext';

/**
 * The five weights the type scale uses, imported one by one: the package root
 * `require`s all fourteen files (about 700 KB), five weights are about 240 KB.
 */
const FONT_SOURCES: Record<string, number> = {
  [FONT_FAMILY[400]]: AtkinsonHyperlegibleNext_400Regular,
  [FONT_FAMILY[500]]: AtkinsonHyperlegibleNext_500Medium,
  [FONT_FAMILY[600]]: AtkinsonHyperlegibleNext_600SemiBold,
  [FONT_FAMILY[700]]: AtkinsonHyperlegibleNext_700Bold,
  [FONT_FAMILY[800]]: AtkinsonHyperlegibleNext_800ExtraBold,
};

function allLoaded(): boolean {
  return Object.keys(FONT_SOURCES).every((family) => isLoaded(family));
}

/**
 * Loads Atkinson Hyperlegible Next without ever holding up start-up.
 *
 * The root gate waits for the database and the household session, never for
 * fonts (brief decision 2): until they arrive, or forever if they fail, text
 * renders in the system font at the same numeric weight, and when they arrive
 * text re-renders once. No layout depends on font metrics, so nothing jumps.
 */
export function FontProvider({ children }: { children: ReactNode }) {
  // Already registered after a fast refresh or a remount: skip the system-font frame.
  const [fontsReady, setFontsReady] = useState(allLoaded);
  const [boldText, setBoldText] = useState(false);

  useEffect(() => {
    if (fontsReady) return;
    let active = true;
    loadAsync(FONT_SOURCES).then(
      () => {
        if (active) setFontsReady(true);
      },
      // Never shown: the system font is a complete fallback.
      () => logError('fonts_failed'),
    );
    return () => {
      active = false;
    };
  }, [fontsReady]);

  useEffect(() => {
    if (Platform.OS !== 'ios') return;
    let active = true;
    AccessibilityInfo.isBoldTextEnabled()
      .then((value) => {
        if (active) setBoldText(value);
      })
      .catch(() => undefined);
    const subscription = AccessibilityInfo.addEventListener('boldTextChanged', setBoldText);
    return () => {
      active = false;
      subscription.remove();
    };
  }, []);

  const value = useMemo(() => ({ fontsReady, boldText }), [fontsReady, boldText]);

  return <FontContext.Provider value={value}>{children}</FontContext.Provider>;
}
