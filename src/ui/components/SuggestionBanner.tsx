import { strings } from '@/i18n/strings';
import { FAILURE_MESSAGES, type RecognitionFailureReason } from '@/services/ai/contract';
import { Banner } from '@/ui/components/Banner';

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
  if (state.status === 'idle') return null;

  if (state.status === 'running' || state.status === 'refreshing') {
    return (
      <Banner
        tone="info"
        icon="sparkle"
        message={
          state.status === 'refreshing'
            ? strings.suggestions.refreshing
            : strings.suggestions.running
        }
      />
    );
  }

  if (state.status === 'applied' || state.status === 'refreshed') {
    return (
      <Banner
        tone="info"
        icon="sparkle"
        title={
          state.status === 'refreshed'
            ? strings.suggestions.refreshed(state.forName)
            : strings.suggestions.applied
        }
        message={strings.suggestions.check}
      />
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
      <Banner
        tone="info"
        icon="sparkle"
        live="off"
        title={strings.suggestions.stale(state.forName)}
        message={strings.suggestions.staleBody}
        action={
          onRefresh
            ? {
                label: strings.suggestions.update,
                onPress: onRefresh,
                accessibilityHint: strings.suggestions.updateHint,
              }
            : undefined
        }
      />
    );
  }

  // A failure is a choice to type the details, not a warning, so it stays quiet.
  return (
    <Banner
      tone="info"
      icon="edit"
      title={strings.suggestions.failed}
      message={FAILURE_MESSAGES[state.reason]}
      action={
        onRetry && state.reason !== 'not_configured'
          ? { label: strings.suggestions.retry, onPress: onRetry }
          : undefined
      }
    />
  );
}
