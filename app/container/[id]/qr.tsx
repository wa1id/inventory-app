import { useState } from 'react';
import { Alert, Share, StyleSheet, Text, View } from 'react-native';
import { useLocalSearchParams } from 'expo-router';
import QRCode from 'react-native-qrcode-svg';

import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { formatQrPayload } from '@/repositories/qr';
import { logEvent } from '@/services/telemetry';
import { Button } from '@/ui/components/Button';
import { ErrorState, LoadingState, Screen } from '@/ui/components/Screen';
import { radius, spacing, useTheme } from '@/ui/theme';

/**
 * Shows the container's QR label so it can be printed or shared when the user
 * has no preprinted sticker (issue #10).
 */
export default function ContainerQrScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const { colors } = useTheme();
  const [busy, setBusy] = useState(false);

  const container = useInventoryQuery(() => repos.containers.getById(id), `container:${id}`);
  const binding = useInventoryQuery(() => repos.qr.getByContainer(id), `qr-of:${id}`);

  async function generate() {
    setBusy(true);
    try {
      await repos.qr.createAndBind(id);
      logEvent('qr_generated');
      invalidate();
      binding.reload();
    } finally {
      setBusy(false);
    }
  }

  function confirmReplace() {
    Alert.alert(
      'Replace this label?',
      'The current sticker will stop opening this container. Only do this if the label is lost or damaged.',
      [
        { text: strings.common.cancel, style: 'cancel' },
        { text: 'Replace', style: 'destructive', onPress: generate },
      ],
    );
  }

  function confirmUnbind() {
    Alert.alert(
      'Remove this label?',
      'The container and everything in it stay exactly as they are. The sticker just stops opening it.',
      [
        { text: strings.common.cancel, style: 'cancel' },
        {
          text: 'Remove',
          style: 'destructive',
          onPress: async () => {
            await repos.qr.unbind(id);
            logEvent('qr_unbound');
            invalidate();
            binding.reload();
          },
        },
      ],
    );
  }

  if (container.loading && !container.data) {
    return (
      <Screen>
        <LoadingState />
      </Screen>
    );
  }

  if (container.error || !container.data) {
    return (
      <Screen>
        <ErrorState
          message={container.error ?? 'That container no longer exists.'}
          onRetry={container.reload}
        />
      </Screen>
    );
  }

  const title = container.data.name ?? container.data.shortCode;
  const token = binding.data?.token ?? null;

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <View style={styles.content}>
        {token ? (
          <>
            <View style={[styles.qrFrame, { backgroundColor: '#FFFFFF' }]}>
              {/* Always rendered on white: scanners need the contrast even in dark mode. */}
              <QRCode value={formatQrPayload(token)} size={220} backgroundColor="#FFFFFF" />
            </View>
            <Text style={[styles.caption, { color: colors.text }]}>{title}</Text>
            <Text style={[styles.code, { color: colors.textMuted }]}>
              {container.data.shortCode}
            </Text>
            <Text style={[styles.hint, { color: colors.textMuted }]}>
              Print this and stick it on the container. Scanning it opens this container straight
              away.
            </Text>

            <View style={styles.actions}>
              <Button
                label="Share label"
                variant="secondary"
                fullWidth
                onPress={() =>
                  Share.share({
                    message: `${title} (${container.data?.shortCode})\n${formatQrPayload(token)}`,
                  })
                }
              />
              <Button label="Replace label" variant="ghost" fullWidth onPress={confirmReplace} />
              <Button label="Remove label" variant="ghost" fullWidth onPress={confirmUnbind} />
            </View>
          </>
        ) : (
          <>
            <Text style={styles.glyph}>🏷️</Text>
            <Text style={[styles.caption, { color: colors.text }]}>No label yet</Text>
            <Text style={[styles.hint, { color: colors.textMuted }]}>
              Generate a QR code to print, or scan a preprinted sticker from the Scan tab to link it
              to this container.
            </Text>
            <View style={styles.actions}>
              <Button label="Generate a QR label" fullWidth onPress={generate} loading={busy} />
            </View>
          </>
        )}
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.xl,
    gap: spacing.sm,
  },
  qrFrame: {
    padding: spacing.lg,
    borderRadius: radius.lg,
    marginBottom: spacing.md,
  },
  glyph: {
    fontSize: 48,
  },
  caption: {
    fontSize: 20,
    fontWeight: '700',
    textAlign: 'center',
  },
  code: {
    fontSize: 15,
    letterSpacing: 1,
  },
  hint: {
    fontSize: 15,
    lineHeight: 21,
    textAlign: 'center',
    marginTop: spacing.sm,
  },
  actions: {
    alignSelf: 'stretch',
    gap: spacing.sm,
    marginTop: spacing.xl,
  },
});
