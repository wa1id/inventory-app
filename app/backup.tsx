import { useEffect, useRef, useState, type ReactNode } from 'react';
import {
  AccessibilityInfo,
  KeyboardAvoidingView,
  ScrollView,
  Share,
  StyleSheet,
  View,
} from 'react-native';
import { useHeaderHeight } from 'expo-router/react-navigation';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useNow } from '@/hooks/useNow';
import { ago } from '@/i18n/format';
import { strings } from '@/i18n/strings';
import { useHousehold } from '@/providers/HouseholdProvider';
import { useSync, type SyncStatus } from '@/providers/SyncProvider';
import { useToast } from '@/providers/ToastProvider';
import { loadAccount, type Account } from '@/services/account/identity';
import { formatRecoveryCode } from '@/services/account/base32';
import { logError } from '@/services/telemetry';
import { spellCode } from '@/ui/a11y';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { Button } from '@/ui/components/Button';
import { CodeInput } from '@/ui/components/CodeInput';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { Sheet } from '@/ui/components/Sheet';
import { confirm } from '@/ui/confirm';
import { haptics } from '@/ui/haptics';
import { CODE_LENGTH, codeProblem } from '@/ui/household/join';
import { backupReason } from '@/ui/household/status';
import { GUTTER, radius, space, useTheme } from '@/ui/theme';

/**
 * Off-device backup: opt-in, no account, a 26-character recovery code as the
 * only key (`SyncProvider`). Laid out by state, one thing to do at a time:
 * turn it on or restore; write the code down; see that it is on.
 *
 * Failure cases: a failed backup is said plainly with "Try again"
 * instead of "Last backup: in progress…"; restoring asks before it
 * replaces what is on this phone; a restore that fails leaves backup off
 * rather than adopting the code (in `SyncProvider`). The code can be
 * shared to Notes or a password manager, since there is no clipboard module.
 */
export default function BackupScreen() {
  const { status } = useSync();
  const { session } = useHousehold();
  const insets = useSafeAreaInsets();
  const headerHeight = useHeaderHeight();
  const [revealedCode, setRevealedCode] = useState<string | null>(null);
  // A restore adopts the code before downloading, so the status carries an
  // account while it runs. The restore form stays up meanwhile: switching to
  // "Backup is on" would unmount it, losing the typed code and the reason a
  // failed restore gives (the provider turns backup back off).
  const [restoring, setRestoring] = useState(false);

  const account = 'account' in status ? status.account : null;

  return (
    <ScreenFrame kind="detail">
      <KeyboardAvoidingView
        behavior="padding"
        keyboardVerticalOffset={headerHeight}
        style={styles.fill}
      >
        <ScrollView
          keyboardShouldPersistTaps="handled"
          contentContainerStyle={[styles.content, { paddingBottom: insets.bottom + space.xl }]}
        >
          {session ? <Banner tone="info" message={strings.backup.pairedNote} /> : null}
          {status.state === 'unavailable' ? (
            <Banner tone="info" message={strings.backup.unavailable} />
          ) : revealedCode ? (
            <RevealedCode code={revealedCode} onSaved={() => setRevealedCode(null)} />
          ) : account && !restoring ? (
            <BackupOn status={status} account={account} onShowCode={setRevealedCode} />
          ) : (
            <BackupOff onEnabled={setRevealedCode} onRestoring={setRestoring} />
          )}
        </ScrollView>
      </KeyboardAvoidingView>
    </ScreenFrame>
  );
}

/** A titled block of the page: a heading, its sentences, then its actions. */
function Part({ title, children }: { title: string; children: ReactNode }) {
  return (
    <View style={styles.part}>
      <AppText variant="heading">{title}</AppText>
      {children}
    </View>
  );
}

/** Backup is off: turn it on, or bring a backup onto this phone with its code. */
function BackupOff({
  onEnabled,
  onRestoring,
}: {
  onEnabled: (code: string) => void;
  /** While a restore runs, so the screen keeps this form up (see `restoring`). */
  onRestoring: (restoring: boolean) => void;
}) {
  const { enable, restoreFromCode } = useSync();
  const toast = useToast();
  const [busy, setBusy] = useState<'enable' | 'restore' | null>(null);
  const busyRef = useRef(false);
  const [enableFailure, setEnableFailure] = useState<string | null>(null);
  const [code, setCode] = useState('');
  const [codeError, setCodeError] = useState<string | null>(null);

  async function turnOn() {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy('enable');
    setEnableFailure(null);
    try {
      const result = await enable();
      if (result.ok) {
        onEnabled(result.account.recoveryCode);
        return;
      }
      // A failed first upload has still created the account, and backups will
      // keep trying under it, so its code is shown now as after any enable
      // (the status card then carries the reason and "Try again"), not only
      // behind "Show recovery code". No account means nothing
      // was created (no database yet), so the reason shows here instead.
      const created = await loadAccount();
      if (created) onEnabled(created.recoveryCode);
      else setEnableFailure(backupReason(result.reason));
    } catch (cause) {
      logError('backup_enable_failed', {
        errorClass: cause instanceof Error ? cause.name : 'unknown',
      });
      setEnableFailure(backupReason('server_error'));
    } finally {
      busyRef.current = false;
      setBusy(null);
    }
  }

  async function restore() {
    if (busyRef.current) return;
    // Checked here so a mistyped code never reaches the "replace everything" question.
    const problem = codeProblem(code, CODE_LENGTH);
    if (problem) {
      setCodeError(
        problem.kind === 'chars'
          ? strings.backup.badChars(problem.chars)
          : backupReason('malformed'),
      );
      haptics.error();
      return;
    }
    busyRef.current = true;
    const ok = await confirm({
      title: strings.backup.restoreConfirmTitle,
      body: strings.backup.restoreConfirmBody,
      confirmLabel: strings.backup.restoreConfirm,
    });
    if (!ok) {
      busyRef.current = false;
      return;
    }
    setBusy('restore');
    setCodeError(null);
    onRestoring(true);
    try {
      const result = await restoreFromCode(code);
      if (result.ok) {
        setCode('');
        haptics.success();
        toast.show({ message: strings.backup.restored });
      } else {
        // Under the field, with the code still typed, so it can be corrected.
        setCodeError(backupReason(result.reason));
        haptics.error();
      }
    } catch (cause) {
      logError('backup_restore_failed', {
        errorClass: cause instanceof Error ? cause.name : 'unknown',
      });
      setCodeError(backupReason('server_error'));
      haptics.error();
    } finally {
      busyRef.current = false;
      setBusy(null);
      onRestoring(false);
    }
  }

  return (
    <>
      <Part title={strings.backup.keepTitle}>
        <AppText variant="body" tone="graphite">
          {strings.backup.keepBody}
        </AppText>
        <AppText variant="body" tone="graphite">
          {strings.backup.keepCode}
        </AppText>
        {enableFailure ? <Banner tone="warning" message={enableFailure} /> : null}
        <Button
          label={strings.backup.turnOn}
          onPress={() => void turnOn()}
          loading={busy === 'enable'}
          disabled={busy === 'restore'}
          accessibilityHint={strings.backup.turnOnHint}
          fullWidth
          testID="backup-enable"
        />
      </Part>

      <Part title={strings.backup.restoreTitle}>
        <AppText variant="body" tone="graphite">
          {strings.backup.restoreBody}
        </AppText>
        <CodeInput
          label={strings.backup.codeLabel}
          hint={strings.backup.codeHint}
          value={code}
          length={CODE_LENGTH}
          onChangeValue={(next) => {
            setCode(next);
            setCodeError(null);
          }}
          error={codeError}
          testID="backup-code-input"
        />
        <Button
          label={strings.backup.restore}
          onPress={() => void restore()}
          loading={busy === 'restore'}
          disabled={code.length === 0 || busy === 'enable'}
          variant="secondary"
          fullWidth
          testID="backup-restore"
        />
      </Part>
    </>
  );
}

/** The code, once: write it down or share it somewhere safe. */
function RevealedCode({ code, onSaved }: { code: string; onSaved: () => void }) {
  const { colors } = useTheme();
  const formatted = formatRecoveryCode(code);

  function share() {
    // Share sheet, so it can go to Notes or a password manager; dismissing it is fine.
    Share.share({ message: formatted }).catch(() => undefined);
  }

  return (
    <Part title={strings.backup.writeDownTitle}>
      <AppText variant="body" tone="graphite">
        {strings.backup.writeDownBody}
      </AppText>
      <View style={[styles.codeBox, { backgroundColor: colors.sheet2 }]}>
        {/* Spelt out for screen readers, so it can be written down letter by letter. */}
        <AppText variant="code" selectable center accessibilityLabel={spellCode(formatted)}>
          {formatted}
        </AppText>
      </View>
      <Button
        label={strings.backup.share}
        onPress={share}
        icon="share"
        variant="secondary"
        fullWidth
        testID="backup-share-code"
      />
      <Button label={strings.backup.saved} onPress={onSaved} fullWidth />
    </Part>
  );
}

/** Backup has an account: when it last ran, run it now, and the way back to the code. */
function BackupOn({
  status,
  account,
  onShowCode,
}: {
  status: SyncStatus;
  account: Account;
  onShowCode: (code: string) => void;
}) {
  const { backupNow } = useSync();
  // "5 minutes ago" keeps up while the screen is open.
  const now = useNow(60_000);
  const working = status.state === 'working';
  const failed = status.state === 'error';
  // "Back up now" and "Try again" can both be tapped before the status says
  // "working"; one press must not start two uploads.
  const runningRef = useRef(false);

  const lastLine =
    status.state === 'working'
      ? strings.backup.working
      : status.state === 'idle'
        ? status.lastBackupAt === null
          ? strings.backup.noBackupYet
          : strings.backup.lastBackup(ago(status.lastBackupAt, now))
        : null;

  // A finished backup is said once. The line itself is not a live region:
  // it ticks every minute, and TalkBack would read each tick aloud. A failure
  // is said by its banner.
  const previousState = useRef(status.state);
  useEffect(() => {
    if (previousState.current === 'working' && status.state === 'idle' && lastLine) {
      AccessibilityInfo.announceForAccessibility(lastLine);
    }
    previousState.current = status.state;
  }, [status.state, lastLine]);

  async function runNow() {
    if (runningRef.current) return;
    runningRef.current = true;
    try {
      // Failures arrive as the provider's `error` status, shown in the banner.
      await backupNow();
    } catch (cause) {
      logError('backup_now_failed', {
        errorClass: cause instanceof Error ? cause.name : 'unknown',
      });
    } finally {
      runningRef.current = false;
    }
  }

  return (
    <>
      {status.state === 'error' ? (
        // Above the card, never "in progress…" for a failure. A failed
        // "Back up now" lands here too, through the provider's status.
        <Banner
          tone="warning"
          title={strings.backup.errorTitle}
          message={backupReason(status.reason)}
          action={{ label: strings.common.tryAgain, onPress: () => void runNow() }}
        />
      ) : null}

      <Sheet inset style={styles.card}>
        <AppText variant="heading">{strings.backup.onTitle}</AppText>
        {lastLine ? <AppText variant="meta">{lastLine}</AppText> : null}
        <AppText variant="body" tone="graphite">
          {strings.backup.automatic}
        </AppText>
        {failed ? null : (
          <Button
            label={strings.backup.backUpNow}
            onPress={() => void runNow()}
            loading={working}
            variant="secondary"
            fullWidth
            testID="backup-now"
          />
        )}
      </Sheet>

      <Part title={strings.backup.codeTitle}>
        <AppText variant="body" tone="graphite">
          {strings.backup.codeBody}
        </AppText>
        <Button
          label={strings.backup.showCode}
          onPress={() => onShowCode(account.recoveryCode)}
          variant="secondary"
          fullWidth
          testID="backup-show-code"
        />
      </Part>
    </>
  );
}

const styles = StyleSheet.create({
  fill: {
    flex: 1,
  },
  content: {
    padding: GUTTER,
    gap: space.xl,
  },
  part: {
    gap: space.md,
  },
  card: {
    gap: space.sm,
  },
  codeBox: {
    borderRadius: radius.card,
    borderCurve: 'continuous',
    paddingVertical: space.lg,
    paddingHorizontal: space.md,
  },
});
