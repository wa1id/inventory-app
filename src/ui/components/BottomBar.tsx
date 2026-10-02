import { Children, useState, type ReactNode } from 'react';
import { StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useKeyboardInset } from '@/hooks/useKeyboardInset';
import { useLayoutScale } from '@/hooks/useLayoutScale';
import { useBottomChrome } from '@/providers/ToastProvider';
import { BOTTOM_BAR_PADDING, ROW_GAP, useTheme } from '@/ui/theme';

export interface BottomBarProps {
  /**
   * One or two `fullWidth` buttons, secondary first: the last child is the
   * primary and sits on the right, where the thumb is.
   */
  children: ReactNode;
  /** Stack the buttons (primary on top) at large text and on narrow phones. */
  stackOnLarge?: boolean;
  testID?: string;
}

/**
 * The bar that holds a screen's primary action, pinned under the content.
 *
 * In reach of the thumb and never hidden by the keyboard, which is why modal
 * forms put Save here rather than in the header. While the keyboard is up it
 * drops the home-indicator inset it would otherwise leave under the buttons.
 * Toasts float just above it while its screen is focused.
 */
export function BottomBar({ children, stackOnLarge = true, testID }: BottomBarProps) {
  const { colors } = useTheme();
  const insets = useSafeAreaInsets();
  const keyboard = useKeyboardInset();
  const { stacked } = useLayoutScale();
  const items = Children.toArray(children);
  const stack = stackOnLarge && stacked && items.length > 1;
  const [height, setHeight] = useState(0);
  useBottomChrome(height);

  return (
    <View
      testID={testID}
      onLayout={(event) => setHeight(Math.round(event.nativeEvent.layout.height))}
      style={[
        styles.bar,
        {
          backgroundColor: colors.sheet,
          borderTopColor: colors.rule,
          paddingBottom: BOTTOM_BAR_PADDING.bottom + (keyboard.visible ? 0 : insets.bottom),
        },
        stack ? styles.stacked : styles.row,
      ]}
    >
      {items.map((child, index) => {
        const primary = index === items.length - 1;
        return (
          <View
            key={index}
            style={
              stack
                ? styles.cellStacked
                : primary && items.length > 1
                  ? styles.primary
                  : styles.cell
            }
          >
            {child}
          </View>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  bar: {
    borderTopWidth: 1,
    paddingTop: BOTTOM_BAR_PADDING.top,
    paddingHorizontal: BOTTOM_BAR_PADDING.sides,
    gap: ROW_GAP,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  // Primary last in the children, first on screen.
  stacked: {
    flexDirection: 'column-reverse',
  },
  cell: {
    flex: 1,
  },
  primary: {
    flex: 1.4,
  },
  cellStacked: {
    alignSelf: 'stretch',
  },
});
