import type { ReactNode } from 'react';
import {
  Pressable,
  StyleSheet,
  View,
  type AccessibilityRole,
  type AccessibilityState,
} from 'react-native';

import { useLayoutScale } from '@/hooks/useLayoutScale';
import { Icon } from '@/ui/components/Icon';
import { PressedOverlay, rippleFor, useFocusRing } from '@/ui/components/PressFeedback';
import { ROW_GAP, ROW_MIN, ROW_PADDING, space, useTheme } from '@/ui/theme';

export interface RowProps {
  /** Absent for a static row. */
  onPress?: () => void;
  leading?: ReactNode;
  /** The text column. */
  children?: ReactNode;
  /** Non-interactive content at the end, inside the pressable (a "×4" badge). */
  aside?: ReactNode;
  chevron?: boolean;
  /** An interactive control, rendered beside the pressable, never inside it. */
  tool?: ReactNode;
  /** Full-width content under the row (the inline stepper). */
  below?: ReactNode;
  selected?: boolean;
  /**
   * Not pressable and announced as disabled. Not dimmed, so "Here now" stays
   * readable; callers draw their text in graphite.
   */
  disabled?: boolean;
  /** 72 by default; 56 for options, 96 for photo rows. */
  minHeight?: number;
  /** Required when pressable: the whole row is one element with this label. */
  accessibilityLabel?: string;
  accessibilityHint?: string;
  accessibilityRole?: AccessibilityRole;
  accessibilityState?: AccessibilityState;
  testID?: string;
}

/**
 * The base of every list row.
 *
 * A row that carries a control renders it as a sibling of its pressable area,
 * so a stepper or a "File…" button is never a pressable inside a pressable
 * (B11): screen readers get two clean focus stops, and a tap on the control
 * can never also open the row. At large text the control drops to its own
 * line under the text instead of squeezing it.
 */
export function Row({
  onPress,
  leading,
  children,
  aside,
  chevron = false,
  tool,
  below,
  selected = false,
  disabled = false,
  minHeight = ROW_MIN,
  accessibilityLabel,
  accessibilityHint,
  accessibilityRole = 'button',
  accessibilityState,
  testID,
}: RowProps) {
  const { colors } = useTheme();
  const { stacked } = useLayoutScale();
  const focus = useFocusRing();
  const stackTool = stacked && Boolean(tool);
  // Fill the width beside a tool; under a stacked layout, size to the text so
  // wrapped lines at large text are never cut off.
  const pressLayout = [styles.press, stackTool ? null : styles.fill, { minHeight }];

  const content = (
    <>
      {leading}
      <View style={styles.text}>{children}</View>
      {aside}
      {chevron ? <Icon name="chevronRight" size={20} color={colors.graphite} /> : null}
    </>
  );

  return (
    <View
      testID={onPress ? undefined : testID}
      style={selected ? { backgroundColor: colors.selected } : null}
    >
      <View style={[stackTool ? styles.lineStacked : styles.line, { minHeight }]}>
        {onPress ? (
          <Pressable
            testID={testID}
            onPress={onPress}
            onFocus={focus.onFocus}
            onBlur={focus.onBlur}
            disabled={disabled}
            accessibilityRole={accessibilityRole}
            accessibilityLabel={accessibilityLabel}
            accessibilityHint={accessibilityHint}
            accessibilityState={{
              ...accessibilityState,
              disabled,
              // "Not selected" is only worth saying for a choice.
              selected: accessibilityRole === 'radio' ? selected : selected || undefined,
            }}
            android_ripple={rippleFor(colors)}
            style={[pressLayout, focus.ringStyle]}
          >
            {({ pressed }) => (
              <>
                <PressedOverlay pressed={pressed} />
                {content}
              </>
            )}
          </Pressable>
        ) : (
          <View
            style={pressLayout}
            accessible={accessibilityLabel !== undefined}
            accessibilityLabel={accessibilityLabel}
          >
            {content}
          </View>
        )}
        {tool ? (
          <View style={stackTool ? styles.toolStacked : styles.tool}>
            {/* Its own box, so a control that holds itself to the start (a
                Button) still lines up at the end when stacked. */}
            <View>{tool}</View>
          </View>
        ) : null}
      </View>
      {below}
      {selected ? <View style={[styles.bar, { backgroundColor: colors.ink }]} /> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  line: {
    flexDirection: 'row',
    alignItems: 'stretch',
  },
  lineStacked: {
    flexDirection: 'column',
  },
  press: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: ROW_GAP,
    paddingVertical: ROW_PADDING.vertical,
    paddingStart: ROW_PADDING.start,
    paddingEnd: ROW_PADDING.end,
  },
  fill: {
    flex: 1,
  },
  text: {
    flex: 1,
    minWidth: 0,
    gap: space.xxs,
  },
  tool: {
    justifyContent: 'center',
    paddingEnd: space.md,
  },
  toolStacked: {
    alignItems: 'flex-end',
    paddingEnd: space.md,
    paddingBottom: ROW_PADDING.vertical,
  },
  bar: {
    position: 'absolute',
    start: 0,
    top: 0,
    bottom: 0,
    width: 3,
  },
});
