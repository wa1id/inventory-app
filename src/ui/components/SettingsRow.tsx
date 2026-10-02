import type { ReactNode } from 'react';
import { StyleSheet, View } from 'react-native';

import { useLayoutScale } from '@/hooks/useLayoutScale';
import { AppText } from '@/ui/components/AppText';
import { Icon, type IconName } from '@/ui/components/Icon';
import { Row } from '@/ui/components/Row';
import { OPTION_MIN, space, useTheme } from '@/ui/theme';

export interface SettingsRowProps {
  icon?: IconName;
  label: string;
  /** The current state, always spoken with the label ("Household, Joined as …"). */
  value?: string;
  tone?: 'ink' | 'signal';
  onPress?: () => void;
  /** Set when the row expands content in place instead of opening a screen. */
  expanded?: boolean;
  testID?: string;
}

/**
 * A settings line: label and current value. The value is part of the spoken
 * label, so a screen reader hears what a row is set to before opening it
 * (UX-17). At large text the value moves under the label instead of
 * squeezing it.
 */
export function SettingsRow({
  icon,
  label,
  value,
  tone = 'ink',
  onPress,
  expanded,
  testID,
}: SettingsRowProps) {
  const { colors } = useTheme();
  const { stacked } = useLayoutScale();
  const toggles = expanded !== undefined;

  const valueText = value ? (
    <AppText
      variant="meta"
      tone={tone === 'signal' ? 'signal' : 'graphite'}
      style={stacked ? null : styles.valueAside}
    >
      {value}
    </AppText>
  ) : null;

  return (
    <Row
      onPress={onPress}
      leading={icon ? <Icon name={icon} size={20} color={colors.graphite} /> : null}
      aside={
        <>
          {stacked ? null : valueText}
          {onPress && toggles ? (
            <View style={expanded ? styles.flipped : null}>
              <Icon name="chevronDown" size={20} color={colors.graphite} />
            </View>
          ) : null}
        </>
      }
      chevron={Boolean(onPress) && !toggles}
      minHeight={OPTION_MIN}
      accessibilityLabel={value ? `${label}, ${value}` : label}
      accessibilityState={toggles ? { expanded } : undefined}
      testID={testID}
    >
      <AppText variant="name">{label}</AppText>
      {stacked ? valueText : null}
    </Row>
  );
}

export interface FactRowProps {
  label: string;
  /** Plain text (notes keep their line breaks) or nodes such as tag chips. */
  children: ReactNode;
}

/** A labelled fact on the item screen: "Category" over "Tools". */
export function FactRow({ label, children }: FactRowProps) {
  return (
    <View style={styles.fact}>
      <AppText variant="factLabel" tone="graphite">
        {label}
      </AppText>
      {typeof children === 'string' ? (
        <AppText variant="body" selectable>
          {children}
        </AppText>
      ) : (
        children
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  valueAside: {
    flexShrink: 1,
    maxWidth: '50%',
    textAlign: 'right',
  },
  flipped: {
    transform: [{ rotate: '180deg' }],
  },
  fact: {
    gap: space.xs,
  },
});
