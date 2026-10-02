import type { ReactNode } from 'react';
import { StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';

import { AppText } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import type { IconName } from '@/ui/components/Icon';
import { radius, space, useTheme, type ThemeColors } from '@/ui/theme';

/** Rules are a full point: `hairlineWidth` vanishes with this pale rule on 3× screens. */
const RULE = 1;

export interface SheetProps {
  children?: ReactNode;
  /** Pads non-list content (a card's text and buttons). */
  inset?: boolean;
  style?: StyleProp<ViewStyle>;
  testID?: string;
}

/**
 * One white sheet on the plaster wall: a bordered list or card, the desk's
 * basic surface. No shadow; the 1 pt rule is the edge. Pressed overlays and
 * ripples clip to its corners.
 */
export function Sheet({ children, inset = false, style, testID }: SheetProps) {
  const { colors } = useTheme();
  return (
    <View
      testID={testID}
      style={[
        styles.sheet,
        { backgroundColor: colors.sheet, borderColor: colors.rule },
        inset ? styles.inset : null,
        style,
      ]}
    >
      {children}
    </View>
  );
}

/**
 * Per-cell styles that make the rows of a virtualised list look like one
 * bordered `Sheet` without wrapping the list in a View (which would defeat
 * virtualisation): side borders on every cell, the top edge and corners on the
 * first, the bottom edge and corners on the last. Separators come from
 * `SheetSeparator` as the list's `ItemSeparatorComponent`.
 */
export function sheetCell(
  index: number,
  count: number,
  colors: Pick<ThemeColors, 'sheet' | 'rule'>,
): ViewStyle {
  const first = index === 0;
  const last = index === count - 1;
  return {
    backgroundColor: colors.sheet,
    borderColor: colors.rule,
    borderLeftWidth: RULE,
    borderRightWidth: RULE,
    borderTopWidth: first ? RULE : 0,
    borderBottomWidth: last ? RULE : 0,
    borderTopLeftRadius: first ? radius.sheet : 0,
    borderTopRightRadius: first ? radius.sheet : 0,
    borderBottomLeftRadius: last ? radius.sheet : 0,
    borderBottomRightRadius: last ? radius.sheet : 0,
    borderCurve: 'continuous',
    overflow: 'hidden',
  };
}

/** Full-width 1 pt rule between the rows of a sheet (desk `.row` border-top). */
export function SheetSeparator() {
  const { colors } = useTheme();
  return <View style={[styles.separator, { backgroundColor: colors.rule }]} />;
}

export interface SectionAction {
  label: string;
  onPress: () => void;
  icon?: IconName;
  testID?: string;
}

export interface SectionProps {
  title?: string;
  count?: number;
  action?: SectionAction;
  footer?: string;
  /** The first section on a screen sits directly under the page head. */
  first?: boolean;
  children?: ReactNode;
}

/** A titled group: "Recently added  12" with an optional quiet action at the end. */
export function Section({ title, count, action, footer, first = false, children }: SectionProps) {
  return (
    <View style={first ? null : styles.sectionGap}>
      {title || action ? (
        <View style={styles.titleRow}>
          <View style={styles.titleText}>
            {title ? (
              <AppText variant="section" accessibilityRole="header" style={styles.title}>
                {title}
              </AppText>
            ) : null}
            {count !== undefined ? (
              <AppText variant="caption" tone="graphite" style={styles.count}>
                {count}
              </AppText>
            ) : null}
          </View>
          {action ? (
            <Button
              label={action.label}
              onPress={action.onPress}
              icon={action.icon}
              testID={action.testID}
              variant="quiet"
              size="sm"
            />
          ) : null}
        </View>
      ) : null}
      {children}
      {footer ? (
        <AppText variant="caption" tone="graphite" style={styles.footer}>
          {footer}
        </AppText>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  sheet: {
    borderWidth: RULE,
    borderRadius: radius.sheet,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  inset: {
    padding: space.lg,
  },
  separator: {
    height: RULE,
  },
  sectionGap: {
    marginTop: space.xxl,
  },
  titleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: space.sm,
    marginBottom: space.sm,
    minHeight: 40,
  },
  titleText: {
    flex: 1,
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'baseline',
    columnGap: space.sm,
  },
  title: {
    flexShrink: 1,
  },
  count: {
    fontVariant: ['tabular-nums'],
  },
  footer: {
    marginTop: space.sm,
  },
});
