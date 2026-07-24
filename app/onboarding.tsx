import { useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';

import { strings } from '@/i18n/strings';
import { useOnboarding } from '@/providers/OnboardingProvider';
import { logEvent } from '@/services/telemetry';
import { Button } from '@/ui/components/Button';
import { Screen } from '@/ui/components/Screen';
import { radius, spacing, useTheme } from '@/ui/theme';

/**
 * Three screens explaining capture → store → find (issue #12).
 *
 * Skippable at every step and replayable from Settings. No account, no
 * paywall, nothing to agree to.
 */
export default function OnboardingScreen() {
  const router = useRouter();
  const { colors } = useTheme();
  const { complete } = useOnboarding();
  const [index, setIndex] = useState(0);

  const steps = strings.onboarding.steps;
  const step = steps[index];
  const isLast = index === steps.length - 1;

  async function finish(reason: 'completed' | 'skipped') {
    await complete();
    logEvent('onboarding_finished', { outcome: reason, step: index + 1 });
    router.replace('/');
  }

  if (!step) return null;

  return (
    <Screen edges={['top', 'left', 'right', 'bottom']}>
      <View style={styles.container}>
        <View style={styles.skipRow}>
          <Button
            label={strings.onboarding.skip}
            variant="ghost"
            onPress={() => finish('skipped')}
          />
        </View>

        <View style={styles.body} accessibilityLiveRegion="polite">
          <Text style={styles.glyph} accessibilityElementsHidden importantForAccessibility="no">
            {step.icon}
          </Text>
          <Text style={[styles.title, { color: colors.text }]} accessibilityRole="header">
            {step.title}
          </Text>
          <Text style={[styles.copy, { color: colors.textMuted }]}>{step.body}</Text>
        </View>

        <View style={styles.footer}>
          <View style={styles.dots} accessibilityLabel={`Step ${index + 1} of ${steps.length}`}>
            {steps.map((_, dotIndex) => (
              <View
                key={dotIndex}
                style={[
                  styles.dot,
                  {
                    backgroundColor: dotIndex === index ? colors.primary : colors.border,
                    width: dotIndex === index ? 24 : 8,
                  },
                ]}
              />
            ))}
          </View>

          <Button
            label={isLast ? strings.onboarding.start : strings.onboarding.next}
            fullWidth
            onPress={() => (isLast ? finish('completed') : setIndex((value) => value + 1))}
          />
        </View>
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: spacing.lg,
  },
  skipRow: {
    alignItems: 'flex-end',
  },
  body: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.md,
  },
  glyph: {
    fontSize: 72,
    marginBottom: spacing.lg,
  },
  title: {
    fontSize: 30,
    fontWeight: '800',
    textAlign: 'center',
  },
  copy: {
    fontSize: 17,
    lineHeight: 25,
    textAlign: 'center',
    paddingHorizontal: spacing.md,
  },
  footer: {
    gap: spacing.xl,
    paddingBottom: spacing.lg,
  },
  dots: {
    flexDirection: 'row',
    justifyContent: 'center',
    gap: spacing.sm,
  },
  dot: {
    height: 8,
    borderRadius: radius.pill,
  },
});
