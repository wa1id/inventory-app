import { useRef, useState, type ReactNode } from 'react';
import { KeyboardAvoidingView, ScrollView, StyleSheet, View } from 'react-native';
import Constants from 'expo-constants';
import { useHeaderHeight } from 'expo-router/react-navigation';

import { strings } from '@/i18n/strings';
import { useDatabase } from '@/providers/DatabaseProvider';
import { useHousehold } from '@/providers/HouseholdProvider';
import { appConfig } from '@/services/config';
import { HouseholdHttpError } from '@/services/household/client';
import {
  markJoinedBefore,
  readImportOffer,
  snapshotBeforeJoin,
} from '@/services/household/importOffer';
import { loadHouseholdSession } from '@/services/household/session';
import { logError } from '@/services/telemetry';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { BottomBar } from '@/ui/components/BottomBar';
import { Button } from '@/ui/components/Button';
import { CodeInput } from '@/ui/components/CodeInput';
import { TextField } from '@/ui/components/TextField';
import { haptics } from '@/ui/haptics';
import {
  CODE_LENGTH,
  joinFailure,
  serverHost,
  suggestedPhoneName,
  validateJoin,
  type JoinErrors,
} from '@/ui/household/join';
import { GUTTER, space } from '@/ui/theme';

/** K18: the household is called "Home"; used only if the saved session cannot be read back. */
const FALLBACK_HOUSEHOLD_NAME = 'Home';

export interface Joined {
  /** The household's display name, for "This phone is now part of Home." */
  householdName: string;
  /** This phone kept an inventory of its own before joining, so copying it is on offer. */
  hasImportOffer: boolean;
}

export interface JoinFormProps {
  /** Above the fields: the heading on Household, Back and the heading in onboarding. */
  header?: ReactNode;
  /** Once this phone is part of the household; the caller moves on (back, or the Joined step). */
  onJoined: (joined: Joined) => void;
  /**
   * How far below the top of the screen the form starts, so the keyboard
   * lifts "Join household" clear of it: the native header's height by
   * default; onboarding, which has no header, passes its top safe-area inset.
   */
  keyboardVerticalOffset?: number;
}

/**
 * Joining the household: the household code, a name for this phone and
 * "Join household". Shared by Settings › Household and onboarding, so a new
 * phone and a phone that skipped the intro join the same way (§5.21, flow 6.8).
 *
 * The code field forgives small letters, missing hyphens and the look-alikes
 * I, L and O; the code and name are checked on press, not while typing.
 * Whatever went wrong keeps both fields as typed. The import offer is decided
 * *before* pairing (`snapshotBeforeJoin`), because once joined every household
 * write is mirrored into the local database and counting afterwards would
 * offer to copy the household's own data back into it (spec R19).
 */
export function JoinForm({ header, onJoined, keyboardVerticalOffset }: JoinFormProps) {
  const { state, invalidate } = useDatabase();
  const household = useHousehold();
  const headerHeight = useHeaderHeight();

  const [code, setCode] = useState('');
  const [name, setName] = useState(() => suggestedPhoneName(Constants.deviceName));
  const [errors, setErrors] = useState<JoinErrors>({});
  const [failure, setFailure] = useState<'offline' | 'other' | null>(null);
  const [busy, setBusy] = useState(false);
  // A ref as well as state: the button and the return key can both fire in
  // one frame, and pairing twice would register this phone twice.
  const busyRef = useRef(false);

  async function join() {
    if (busyRef.current) return;
    const found = validateJoin(code, name);
    setErrors(found);
    setFailure(null);
    if (found.code || found.name) {
      haptics.error();
      return;
    }

    busyRef.current = true;
    setBusy(true);
    try {
      // The local database, never the shadowed repositories: this is what the
      // phone holds of its own, before any household write lands in it.
      if (state.status === 'ready') await snapshotBeforeJoin(state.repos);
      await household.pair(code, name.trim());
      await markJoinedBefore();
      // `pair` saved the session before resolving; read back for the household's name.
      const [session, offer] = await Promise.all([loadHouseholdSession(), readImportOffer()]);
      invalidate();
      haptics.success();
      onJoined({
        householdName: session?.householdName ?? FALLBACK_HOUSEHOLD_NAME,
        hasImportOffer: offer !== null,
      });
    } catch (cause) {
      const kind = joinFailure(cause);
      logError('household_join_failed', {
        outcome: kind,
        statusCode: cause instanceof HouseholdHttpError ? cause.status : null,
        errorClass: cause instanceof Error ? cause.name : 'unknown',
      });
      // A refused code belongs under the code; no answer is about the connection.
      if (kind === 'refused') setErrors({ code: strings.join.refused });
      else setFailure(kind);
      haptics.error();
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  }

  return (
    <KeyboardAvoidingView
      behavior="padding"
      // The view measures itself against its parent, not the screen, so the
      // distance from the top of the screen has to be supplied.
      keyboardVerticalOffset={keyboardVerticalOffset ?? headerHeight}
      style={styles.fill}
    >
      <ScrollView
        keyboardShouldPersistTaps="handled"
        contentContainerStyle={styles.content}
        style={styles.fill}
      >
        {header}
        {failure ? (
          <Banner
            tone="warning"
            message={failure === 'offline' ? strings.join.offline : strings.join.other}
            live="assertive"
          />
        ) : null}
        <CodeInput
          label={strings.join.codeLabel}
          hint={strings.join.codeHint}
          value={code}
          length={CODE_LENGTH}
          onChangeValue={(next) => {
            setCode(next);
            setErrors((current) => ({ ...current, code: undefined }));
            setFailure(null);
          }}
          error={errors.code}
          testID="join-code"
        />
        <TextField
          label={strings.join.nameLabel}
          placeholder={strings.join.namePlaceholder}
          hint={strings.join.nameHint}
          value={name}
          onChangeText={(next) => {
            setName(next);
            setErrors((current) => ({ ...current, name: undefined }));
          }}
          error={errors.name}
          required
          autoCapitalize="words"
          autoCorrect={false}
          returnKeyType="go"
          onSubmitEditing={() => void join()}
          testID="join-name"
        />
        <View style={styles.footer}>
          <AppText variant="caption" tone="graphite">
            {strings.household.server(serverHost(appConfig.householdOrigin))}
          </AppText>
        </View>
      </ScrollView>
      <BottomBar>
        <Button
          label={busy ? strings.join.busy : strings.join.submit}
          onPress={() => void join()}
          loading={busy}
          fullWidth
          testID="join-submit"
        />
      </BottomBar>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  fill: {
    flex: 1,
  },
  content: {
    padding: GUTTER,
    paddingBottom: space.xl,
    gap: space.lg,
  },
  footer: {
    paddingTop: space.xs,
  },
});
