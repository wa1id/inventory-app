import { useState } from 'react';
import { Alert, ScrollView, StyleSheet, Text, View } from 'react-native';

import { useSync } from '@/providers/SyncProvider';
import { formatRecoveryCode } from '@/services/account/base32';
import type { SyncFailureReason } from '@/services/sync/contract';
import { Button } from '@/ui/components/Button';
import { Screen } from '@/ui/components/Screen';
import { TextField } from '@/ui/components/TextField';
import { radius, spacing, useTheme } from '@/ui/theme';

/** Plain language for every way this can fail. */
function describe(reason: SyncFailureReason | 'malformed'): string {
  switch (reason) {
    case 'malformed':
      return 'That code is not complete. It is 26 characters, usually written in groups of five.';
    case 'offline':
      return 'No connection. Your inventory is safe on this device — try again when you are back online.';
    case 'timeout':
      return 'The connection timed out before the backup finished. Try again.';
    case 'unauthorized':
      return 'That code was not accepted.';
    case 'not_found':
      return 'There is no backup stored under that code yet.';
    case 'quota_exceeded':
      return 'This account has reached its storage limit.';
    case 'too_large':
      return 'This inventory is too large for a single backup.';
    case 'corrupted':
      return 'That backup could not be read. Nothing on this device was changed.';
    case 'not_configured':
      return 'Backup is not available in this build.';
    default:
      return 'The backup service could not be reached. Your inventory is safe on this device.';
  }
}

function formatWhen(at: number | null): string {
  if (at === null) return 'Never';

  const minutes = Math.floor((Date.now() - at) / 60_000);
  if (minutes < 1) return 'Just now';
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'} ago`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} hour${hours === 1 ? '' : 's'} ago`;

  const days = Math.floor(hours / 24);
  return `${days} day${days === 1 ? '' : 's'} ago`;
}

function Card({ title, children }: { title: string; children: React.ReactNode }) {
  const { colors } = useTheme();
  return (
    <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
      <Text style={[styles.title, { color: colors.text }]} accessibilityRole="header">
        {title}
      </Text>
      {children}
    </View>
  );
}

export default function BackupScreen() {
  const { colors } = useTheme();
  const { status, enable, backupNow, restoreFromCode } = useSync();

  const [busy, setBusy] = useState(false);
  const [revealedCode, setRevealedCode] = useState<string | null>(null);
  const [enteredCode, setEnteredCode] = useState('');
  const [error, setError] = useState<string | null>(null);

  const working = busy || status.state === 'working';

  if (status.state === 'unavailable') {
    return (
      <Screen edges={['left', 'right', 'bottom']}>
        <ScrollView contentContainerStyle={styles.content}>
          <Card title="Backup is not configured">
            <Text style={[styles.body, { color: colors.textMuted }]}>
              This build has no backup service set, so everything stays on this device only.
              Uninstalling the app deletes it.
            </Text>
          </Card>
        </ScrollView>
      </Screen>
    );
  }

  async function handleEnable() {
    setBusy(true);
    setError(null);

    const result = await enable();
    setBusy(false);

    if (!result.ok) {
      setError(describe(result.reason));
      return;
    }
    setRevealedCode(result.account.recoveryCode);
  }

  async function handleRestore() {
    setBusy(true);
    setError(null);

    const result = await restoreFromCode(enteredCode);
    setBusy(false);

    if (!result.ok) {
      setError(describe(result.reason));
      return;
    }

    setEnteredCode('');
    Alert.alert('Restored', 'Your inventory is back. Photos will finish downloading shortly.');
  }

  const account = 'account' in status ? status.account : null;

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        {error ? (
          <View style={[styles.notice, { backgroundColor: colors.dangerSurface }]}>
            <Text style={[styles.body, { color: colors.danger }]}>{error}</Text>
          </View>
        ) : null}

        {status.state === 'off' ? (
          <>
            <Card title="Keep a copy off this device">
              <Text style={[styles.body, { color: colors.textMuted }]}>
                Your inventory lives on this phone. If you lose it, reset it, or uninstall the app,
                it is gone. Turning on backup stores an encrypted-in-transit copy of your database
                and photos so you can get them back.
              </Text>
              <Text style={[styles.body, { color: colors.textMuted }]}>
                There is no account and no email. Instead you get a recovery code — the only thing
                that can reach your backup. Save it somewhere safe; nobody can recover it for you.
              </Text>
              <Button
                label="Turn on backup"
                onPress={handleEnable}
                loading={working}
                fullWidth
                accessibilityHint="Creates a recovery code and uploads a first backup"
              />
            </Card>

            <Card title="Already have a recovery code?">
              <Text style={[styles.body, { color: colors.textMuted }]}>
                Enter it to bring an existing inventory onto this device. This replaces what is
                currently on this phone.
              </Text>
              <TextField
                label="Recovery code"
                value={enteredCode}
                onChangeText={setEnteredCode}
                autoCapitalize="characters"
                autoCorrect={false}
                placeholder="XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-X"
                hint="26 characters. Hyphens and lower case are fine."
              />
              <Button
                label="Restore from code"
                variant="secondary"
                onPress={handleRestore}
                disabled={enteredCode.trim().length === 0}
                loading={working}
                fullWidth
              />
            </Card>
          </>
        ) : null}

        {revealedCode ? (
          <Card title="Write this down now">
            <Text style={[styles.body, { color: colors.textMuted }]}>
              This is the only way back to your backup. It is not stored anywhere else, and it
              cannot be reissued.
            </Text>
            <View style={[styles.codeBox, { backgroundColor: colors.surfaceAlt }]}>
              <Text selectable style={[styles.code, { color: colors.text }]}>
                {formatRecoveryCode(revealedCode)}
              </Text>
            </View>
            <Button label="I have saved it" onPress={() => setRevealedCode(null)} fullWidth />
          </Card>
        ) : null}

        {account && !revealedCode ? (
          <>
            <Card title="Backup is on">
              <Text style={[styles.body, { color: colors.textMuted }]}>
                Last backup:{' '}
                {status.state === 'idle' ? formatWhen(status.lastBackupAt) : 'in progress…'}
              </Text>
              <Text style={[styles.body, { color: colors.textMuted }]}>
                Backups run automatically when you open the app, at most once every 15 minutes.
              </Text>
              <Button label="Back up now" onPress={backupNow} loading={working} fullWidth />
            </Card>

            <Card title="Your recovery code">
              <Text style={[styles.body, { color: colors.textMuted }]}>
                Needed to restore onto a new phone. Treat it like a password — anyone who has it can
                read this inventory.
              </Text>
              {revealedCode === null ? (
                <Button
                  label="Show recovery code"
                  variant="secondary"
                  onPress={() => setRevealedCode(account.recoveryCode)}
                  fullWidth
                />
              ) : null}
            </Card>
          </>
        ) : null}
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: {
    padding: spacing.lg,
    gap: spacing.md,
    paddingBottom: spacing.xxl,
  },
  card: {
    borderRadius: radius.lg,
    borderWidth: 1,
    padding: spacing.lg,
    gap: spacing.sm,
  },
  notice: {
    borderRadius: radius.md,
    padding: spacing.md,
  },
  title: {
    fontSize: 17,
    fontWeight: '700',
  },
  body: {
    fontSize: 15,
    lineHeight: 22,
  },
  codeBox: {
    borderRadius: radius.md,
    paddingVertical: spacing.md,
    paddingHorizontal: spacing.sm,
    alignItems: 'center',
  },
  code: {
    fontSize: 18,
    fontWeight: '700',
    letterSpacing: 1.5,
    fontVariant: ['tabular-nums'],
    textAlign: 'center',
  },
});
