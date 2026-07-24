import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';

import { MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

type Variant = 'primary' | 'secondary' | 'danger' | 'ghost';

interface ButtonProps {
  label: string;
  onPress: () => void;
  variant?: Variant;
  disabled?: boolean;
  loading?: boolean;
  /** Emoji or short glyph rendered before the label; decorative only. */
  icon?: string;
  fullWidth?: boolean;
  accessibilityHint?: string;
  testID?: string;
}

export function Button({
  label,
  onPress,
  variant = 'primary',
  disabled = false,
  loading = false,
  icon,
  fullWidth = false,
  accessibilityHint,
  testID,
}: ButtonProps) {
  const { colors } = useTheme();
  const isDisabled = disabled || loading;

  const background = {
    primary: colors.primary,
    secondary: colors.surfaceAlt,
    danger: colors.danger,
    ghost: 'transparent',
  }[variant];

  const foreground = {
    primary: colors.primaryText,
    secondary: colors.text,
    danger: '#FFFFFF',
    ghost: colors.primary,
  }[variant];

  return (
    <Pressable
      testID={testID}
      onPress={onPress}
      disabled={isDisabled}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityHint={accessibilityHint}
      accessibilityState={{ disabled: isDisabled, busy: loading }}
      style={({ pressed }) => [
        styles.base,
        {
          backgroundColor: background,
          borderColor: variant === 'ghost' ? 'transparent' : background,
          opacity: isDisabled ? 0.5 : pressed ? 0.85 : 1,
          alignSelf: fullWidth ? 'stretch' : 'flex-start',
        },
      ]}
    >
      {loading ? (
        <ActivityIndicator color={foreground} />
      ) : (
        <View style={styles.content}>
          {icon ? (
            <Text style={styles.icon} accessibilityElementsHidden importantForAccessibility="no">
              {icon}
            </Text>
          ) : null}
          <Text style={[styles.label, { color: foreground }]} numberOfLines={2}>
            {label}
          </Text>
        </View>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  base: {
    minHeight: MIN_TOUCH_TARGET,
    paddingHorizontal: spacing.lg,
    paddingVertical: spacing.md,
    borderRadius: radius.md,
    borderWidth: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  content: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
  },
  icon: {
    fontSize: 16,
  },
  label: {
    fontSize: 16,
    fontWeight: '600',
    textAlign: 'center',
  },
});
