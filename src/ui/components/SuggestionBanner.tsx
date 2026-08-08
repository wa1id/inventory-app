import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { FAILURE_MESSAGES, type RecognitionFailureReason } from '@/services/ai/contract';
import { Button } from '@/ui/components/Button';
import { radius, spacing, useTheme } from '@/ui/theme';

export type SuggestionState =
  /**
   * `forName` is the name the rest of the suggestion was derived from — the one
   * we suggested, or the one the user corrected it to on the last refresh. The
   * screen compares it against what is now in the field to notice that the
   * supporting details no longer describe the item.
   */
  | { status: 'idle' }
  | { status: 'running' }
  | { status: 'applied'; confidence: number; forName: string }
  /** Name edited since the details were derived; they describe the old guess. */
  | { status: 'stale'; forName: string }
  | { status: 'refreshing' }
  | { status: 'refreshed'; forName: string }
  | { status: 'failed'; reason: RecognitionFailureReason };

/**
 * The name the supporting fields no longer describe, or null when they still do.
 *
 * Derived from the live field rather than stored on the state, so it follows
 * every edit — including a name typed *before* the first suggestion arrives,
 * where the details land describing the AI's guess while the title is already
 * the user's. Only a suggestion that was actually applied can go stale; a
 * failure has nothing to refresh.
 */
export function staleSuggestionName(state: SuggestionState, typedName: string): string | null {
  if (state.status !== 'applied' && state.status !== 'refreshed') return null;

  const typed = typedName.trim();
  if (typed.length === 0 || typed === state.forName) return null;

  return typed;
}

/**
 * Communicates the state of AI assistance without ever blocking the form.
 *
 * Suggestions are labelled as suggestions, and every failure path offers retry
 * while leaving the fields fully editable (issues #7, #12).
 */
export function SuggestionBanner({
  state,
  onRetry,
  onRefresh,
}: {
  state: SuggestionState;
  onRetry?: () => void;
  /** Re-derives the supporting fields from the name now in the form. */
  onRefresh?: () => void;
}) {
  const { colors } = useTheme();

  if (state.status === 'idle') return null;

  if (state.status === 'running' || state.status === 'refreshing') {
    return (
      <View
        style={[styles.banner, { backgroundColor: colors.surfaceAlt, borderColor: colors.border }]}
        accessibilityLiveRegion="polite"
      >
        <ActivityIndicator color={colors.primary} />
        <Text style={[styles.text, { color: colors.text }]}>
          {state.status === 'refreshing'
            ? 'Working out the details for your title…'
            : 'Looking at your photo… you can start typing now.'}
        </Text>
      </View>
    );
  }

  if (state.status === 'applied' || state.status === 'refreshed') {
    return (
      <View
        style={[styles.banner, { backgroundColor: colors.surfaceAlt, borderColor: colors.border }]}
        accessibilityLiveRegion="polite"
      >
        <Text style={styles.glyph}>✨</Text>
        <View style={styles.body}>
          <Text style={[styles.title, { color: colors.text }]}>
            {state.status === 'refreshed'
              ? `Details updated for “${state.forName}”`
              : 'Suggested from your photo'}
          </Text>
          <Text style={[styles.text, { color: colors.textMuted }]}>
            Check the details and change anything that is wrong.
          </Text>
        </View>
      </View>
    );
  }

  // The name no longer matches what the other fields were derived from. Nothing
  // changes until this is tapped: a suggestion that rewrote fields while the
  // user was still typing the title would be the same overwrite problem in
  // reverse (issue #13).
  if (state.status === 'stale') {
    return (
      // Not a live region, unlike every other state here: this copy follows the
      // name field keystroke by keystroke, so announcing it would talk over
      // someone typing their correction. The other states announce because they
      // arrive on their own, out of the user's control.
      <View
        style={[styles.banner, { backgroundColor: colors.surfaceAlt, borderColor: colors.border }]}
      >
        <Text style={styles.glyph}>✨</Text>
        <View style={styles.body}>
          <Text style={[styles.title, { color: colors.text }]}>
            Title changed to “{state.forName}”
          </Text>
          <Text style={[styles.text, { color: colors.textMuted }]}>
            The category and tags still describe our earlier guess.
          </Text>
          {onRefresh ? (
            <Button
              label="Update the other details"
              variant="ghost"
              onPress={onRefresh}
              accessibilityHint="Replaces the category and tags using your title"
            />
          ) : null}
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
