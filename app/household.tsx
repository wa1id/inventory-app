import { useState } from 'react';
import { Alert, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';

import { useDatabase } from '@/providers/DatabaseProvider';
import { useHousehold } from '@/providers/HouseholdProvider';
import { strings } from '@/i18n/strings';
import { HouseholdHttpError } from '@/services/household/client';
import { Button } from '@/ui/components/Button';
import { Screen } from '@/ui/components/Screen';
import { TextField } from '@/ui/components/TextField';
import { radius, spacing, useTheme } from '@/ui/theme';

export default function HouseholdScreen() {
  const { colors } = useTheme();
  const router = useRouter();
  const { invalidate } = useDatabase();
  const household = useHousehold();
  const [secret, setSecret] = useState('');
  const [deviceName, setDeviceName] = useState('This phone');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function pair() {
    setBusy(true);
    setError(null);
    try {
      await household.pair(secret, deviceName);
      invalidate();
      router.back();
    } catch (cause) {
      setError(
        cause instanceof HouseholdHttpError && cause.code === 'unauthorized'
          ? 'That secret was not accepted.'
          : strings.household.error,
      );
    } finally {
      setBusy(false);
    }
  }

  function confirmDisconnect() {
    Alert.alert(
      strings.household.disconnect,
      'This phone will go back to its local inventory. The household on the server is unchanged.',
      [
        { text: strings.common.cancel, style: 'cancel' },
        {
          text: strings.household.disconnect,
          style: 'destructive',
          onPress: async () => {
            await household.disconnect();
            invalidate();
            router.back();
          },
        },
      ],
    );
  }

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={[styles.body, { color: colors.textMuted }]}>{strings.household.body}</Text>
        <Text style={[styles.hint, { color: colors.textMuted }]}>
          {strings.household.originHint}
        </Text>

        {household.session ? (
          <View
            style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}
          >
            <Text style={[styles.status, { color: colors.text }]}>
              {strings.household.connectedAs(household.session.deviceName)}
            </Text>
            <Text style={[styles.hint, { color: colors.textMuted }]}>
              {household.session.origin}
            </Text>
            <Button
              label={strings.household.disconnect}
              variant="danger"
              onPress={confirmDisconnect}
            />
          </View>
        ) : (
          <View
            style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}
          >
            <TextField
              label={strings.household.secretLabel}
              value={secret}
              onChangeText={setSecret}
              autoCapitalize="characters"
              autoCorrect={false}
              placeholder={strings.household.secretPlaceholder}
              hint={strings.household.secretHint}
            />
            <TextField
              label={strings.household.deviceNameLabel}
              value={deviceName}
              onChangeText={setDeviceName}
            />
            {error ? <Text style={[styles.error, { color: colors.danger }]}>{error}</Text> : null}
            <Button
              label={busy ? strings.household.pairing : strings.household.pair}
              onPress={() => void pair()}
              disabled={busy || secret.trim().length < 8 || deviceName.trim().length === 0}
              loading={busy}
            />
          </View>
        )}
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: { padding: spacing.lg, gap: spacing.lg },
  body: { fontSize: 16, lineHeight: 22 },
  hint: { fontSize: 14, lineHeight: 20 },
  card: { borderWidth: 1, borderRadius: radius.md, padding: spacing.lg, gap: spacing.md },
  status: { fontSize: 17, fontWeight: '600' },
  error: { fontSize: 14 },
});
