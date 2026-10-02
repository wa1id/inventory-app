import { createContext, useContext } from 'react';

export interface FontState {
  /** True once every weight is registered; text uses the system font until then. */
  fontsReady: boolean;
  /** iOS Bold Text, which the system applies to its own font but not to a custom one. */
  boldText: boolean;
}

/**
 * What `FontProvider` knows, kept apart from it so that text components read
 * it without importing the font loader (and its native asset module) along
 * with it.
 *
 * A default instead of a throwing hook: text must render anywhere, including
 * before the provider mounts and in tests, so outside it the answer is simply
 * "system font, regular weights".
 */
export const FontContext = createContext<FontState>({ fontsReady: false, boldText: false });

export function useFontsReady(): boolean {
  return useContext(FontContext).fontsReady;
}

export function useBoldText(): boolean {
  return useContext(FontContext).boldText;
}
