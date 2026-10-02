import type { ReactNode } from 'react';
import { KeyboardAvoidingView, ScrollView, StyleSheet, View } from 'react-native';

import { useSheetKeyboardOffset } from '@/hooks/useSheetKeyboardOffset';
import { strings } from '@/i18n/strings';
import { Banner, type BannerAction } from '@/ui/components/Banner';
import { EmptyState } from '@/ui/components/EmptyState';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { describeError, type ErrorSubject } from '@/ui/errors';
import { goToTab } from '@/ui/navigation';
import { GUTTER, space } from '@/ui/theme';

export interface FormLayoutProps {
  /** A failed save. Above the scroll view, so it is seen whatever was scrolled to. */
  notice?: ReactNode;
  children: ReactNode;
  /** The `BottomBar` holding the form's primary action. */
  bottomBar: ReactNode;
}

/**
 * The frame of the space and container sheets: fields scroll,
 * the primary action stays in a bar at the bottom, and the keyboard pushes
 * that bar up rather than covering it. Before the redesign nothing in the app
 * avoided the keyboard, so Save sat under it on iOS.
 */
export function FormLayout({ notice, children, bottomBar }: FormLayoutProps) {
  const keyboard = useSheetKeyboardOffset();

  return (
    <ScreenFrame kind="modal">
      <KeyboardAvoidingView
        behavior="padding"
        keyboardVerticalOffset={keyboard.keyboardVerticalOffset}
        onLayout={keyboard.onLayout}
        style={styles.fill}
      >
        {notice ? <View style={styles.notice}>{notice}</View> : null}
        <ScrollView
          keyboardShouldPersistTaps="handled"
          contentContainerStyle={styles.content}
          style={styles.fill}
        >
          {children}
        </ScrollView>
        {bottomBar}
      </KeyboardAvoidingView>
    </ScreenFrame>
  );
}

export interface SaveNoticeProps {
  /** What the save threw, or `null` when the record turned out to be gone. */
  cause: unknown;
  subject: ErrorSubject;
  action?: BannerAction;
}

/**
 * Why a save did not happen, in plain words: the raw message used to be
 * written into the name field's error slot. What was typed stays in the form.
 */
export function SaveNotice({ cause, subject, action }: SaveNoticeProps) {
  const described = describeError(cause, 'save', subject);
  return (
    <Banner
      tone="warning"
      // A failed local write is not a failed read: its body ("It was not saved.
      // Try again.") says it all, without the "could not be read" title.
      title={described.kind === 'local' ? undefined : described.title}
      message={described.body}
      action={action}
      live="assertive"
    />
  );
}

/**
 * The drop zone's space and container are real rows, but not ones anyone can
 * rename, move or delete. Nothing links to their edit
 * screens; this answers a stale link instead of showing the form.
 */
export function DropZoneLocked() {
  return (
    <ScreenFrame kind="modal">
      <EmptyState
        icon="inbox"
        title={strings.errors.dropZoneLocked.title}
        body={strings.errors.dropZoneLocked.body}
        action={{
          label: strings.errors.dropZoneLocked.action,
          onPress: () => goToTab('/drop-zone'),
        }}
      />
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  fill: {
    flex: 1,
  },
  notice: {
    paddingHorizontal: GUTTER,
    paddingTop: space.md,
  },
  content: {
    padding: GUTTER,
    paddingBottom: space.xl,
    gap: space.lg,
  },
});
