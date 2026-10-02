import { Pressable, StyleSheet, View } from 'react-native';

import { AppText } from '@/ui/components/AppText';
import { Icon, type IconName } from '@/ui/components/Icon';
import { haptics } from '@/ui/haptics';
import { MIN_TOUCH_TARGET, camera, radius, space, useTheme } from '@/ui/theme';

export interface SegmentOption<T extends string> {
  value: T;
  label: string;
  icon?: IconName;
  testID?: string;
}

export interface SegmentedControlProps<T extends string> {
  options: readonly SegmentOption<T>[];
  value: T;
  onChange: (value: T) => void;
  accessibilityLabel: string;
  /** `camera` sits on the live picture: translucent track, white text. */
  tone?: 'surface' | 'camera';
  disabled?: boolean;
  /** Read on each option, e.g. why the control is locked ("Finish this set first"). */
  accessibilityHint?: string;
}

/** Two to four mutually exclusive options in one track, such as Single and Several. */
export function SegmentedControl<T extends string>({
  options,
  value,
  onChange,
  accessibilityLabel,
  tone = 'surface',
  disabled = false,
  accessibilityHint,
}: SegmentedControlProps<T>) {
  const { colors } = useTheme();
  const onCamera = tone === 'camera';

  return (
    <View
      accessibilityRole="radiogroup"
      accessibilityLabel={accessibilityLabel}
      style={[
        styles.track,
        onCamera
          ? { backgroundColor: camera.chip }
          : { backgroundColor: colors.sheet2, borderColor: colors.control, borderWidth: 1 },
        { opacity: disabled ? 0.45 : 1 },
      ]}
    >
      {options.map((option) => {
        const selected = option.value === value;
        const ink = onCamera ? camera.ink : selected ? colors.ink : colors.graphite;
        return (
          <Pressable
            key={option.value}
            onPress={() => {
              if (selected) return;
              haptics.choice();
              onChange(option.value);
            }}
            disabled={disabled}
            accessibilityRole="radio"
            accessibilityLabel={option.label}
            accessibilityHint={accessibilityHint}
            accessibilityState={{ selected, disabled }}
            testID={option.testID}
            style={[
              styles.segment,
              selected
                ? onCamera
                  ? { backgroundColor: camera.selected }
                  : { backgroundColor: colors.sheet, borderColor: colors.ink, borderWidth: 1 }
                : null,
              onCamera && !selected ? styles.cameraIdle : null,
            ]}
          >
            {option.icon ? <Icon name={option.icon} size={20} color={ink} /> : null}
            <AppText
              variant={selected ? 'name' : 'label'}
              tone={onCamera ? 'camera' : selected ? 'ink' : 'graphite'}
              numberOfLines={1}
              style={styles.segmentText}
            >
              {option.label}
            </AppText>
          </Pressable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  track: {
    flexDirection: 'row',
    minHeight: MIN_TOUCH_TARGET,
    padding: 3,
    gap: 3,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  segment: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.xs + 2,
    paddingHorizontal: space.sm,
    borderRadius: radius.control - 2,
    borderCurve: 'continuous',
  },
  segmentText: {
    flexShrink: 1,
  },
  cameraIdle: {
    opacity: 0.8,
  },
});
