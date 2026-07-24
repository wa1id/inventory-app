import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { FAILURE_MESSAGES, type RecognitionFailureReason } from '@/services/ai/contract';
import { Button } from '@/ui/components/Button';
import { radius, spacing, useTheme } from '@/ui/theme';

export type SuggestionState =
  | { status: 'idle' }
  | { status: 'running' }
  | { status: 'applied'; confidence: number }
  | { status: 'failed'; reason: RecognitionFailureReason };

/**
 * Communicates the state of AI assistance without ever blocking the form.
 *
 * Suggestions are labelled as suggestions, and every failure path offers retry
 * while leaving the fields fully editable (issues #7, #12).
 */
export function SuggestionBanner({
  state,
  onRetry,
}: {
  state: SuggestionState;
  onRetry?: () => void;
}) {
  const { colors } = useTheme();

  if (state.status === 'idle') return null;

  if (state.status === 'running') {
    return (
      <View
        style={[styles.banner, { backgroundColor: colors.surfaceAlt, borderColor: colors.border }]}
        accessibilityLiveRegion="polite"
      >
        <ActivityIndicator color={colors.primary} />
        <Text style={[styles.text, { color: colors.text }]}>
          Looking at your photo… you can start typing now.
        </Text>
      </View>
    );
  }

  if (state.status === 'applied') {
    return (
      <View
        style={[styles.banner, { backgroundColor: colors.surfaceAlt, borderColor: colors.border }]}
        accessibilityLiveRegion="polite"
      >
        <Text style={styles.glyph}>✨</Text>
        <View style={styles.body}>
          <Text style={[styles.title, { color: colors.text }]}>Suggested from your photo</Text>
          <Text style={[styles.text, { color: colors.textMuted }]}>
            Check the details and change anything that is wrong.
          </Text>
        </View>
      </View>
    );
  }

  return (
    <View
      style={[
        styles.banner,
        { backgroundColor: colors.warningSurface, borderColor: colors.border },
      ]}
      accessibilityLiveRegion="polite"
    >
      <Text style={styles.glyph}>✍️</Text>
      <View style={styles.body}>
        <Text style={[styles.title, { color: colors.text }]}>Add the details yourself</Text>
        <Text style={[styles.text, { color: colors.textMuted }]}>
          {FAILURE_MESSAGES[state.reason]}
        </Text>
        {onRetry && state.reason !== 'not_configured' ? (
          <Button label="Try suggestions again" variant="ghost" onPress={onRetry} />
        ) : null}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  banner: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: spacing.md,
    padding: spacing.md,
    borderRadius: radius.md,
    borderWidth: 1,
  },
  glyph: {
    fontSize: 20,
  },
  body: {
    flex: 1,
    gap: spacing.xs,
  },
  title: {
    fontSize: 15,
    fontWeight: '700',
  },
  text: {
    flex: 1,
    fontSize: 14,
    lineHeight: 20,
  },
});
