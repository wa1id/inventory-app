import { useCallback, useLayoutEffect, useRef, useState } from 'react';
import type { LayoutChangeEvent, NativeScrollEvent, NativeSyntheticEvent } from 'react-native';
import { useNavigation } from 'expo-router';

/**
 * A detail screen's title lives in its content, big; the native header stays
 * empty until that title has scrolled up under it, then shows it small.
 *
 * Without this, every detail screen showed its name twice: once in the header
 * and once in the content. Attach `onTitleLayout` to the
 * in-content title's outermost wrapper inside the scroll content, and
 * `onScroll` to the list. The header only changes when the title crosses the
 * header edge, never on every scroll event.
 */
export function useCollapsingTitle(title: string): {
  onScroll: (event: NativeSyntheticEvent<NativeScrollEvent>) => void;
  onTitleLayout: (event: LayoutChangeEvent) => void;
  collapsed: boolean;
} {
  const navigation = useNavigation();
  const [collapsed, setCollapsed] = useState(false);
  const collapsedRef = useRef(false);
  const titleBottomRef = useRef<number | null>(null);

  const onTitleLayout = useCallback((event: LayoutChangeEvent) => {
    const { y, height } = event.nativeEvent.layout;
    titleBottomRef.current = y + height;
  }, []);

  const onScroll = useCallback((event: NativeSyntheticEvent<NativeScrollEvent>) => {
    const bottom = titleBottomRef.current;
    if (bottom === null) return;
    const next = event.nativeEvent.contentOffset.y >= bottom;
    if (next === collapsedRef.current) return;
    collapsedRef.current = next;
    setCollapsed(next);
  }, []);

  // A layout effect, so the header never shows a frame with the wrong title.
  useLayoutEffect(() => {
    navigation.setOptions({ title: collapsed ? title : '', headerShadowVisible: collapsed });
  }, [collapsed, navigation, title]);

  return { onScroll, onTitleLayout, collapsed };
}
