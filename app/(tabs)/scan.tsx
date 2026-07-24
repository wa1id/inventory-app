import { useCallback, useState } from 'react';
import { Alert, FlatList, Linking, Pressable, StyleSheet, Text, View } from 'react-native';
import { CameraView, useCameraPermissions } from 'expo-camera';
import { useFocusEffect, useIsFocused, useRouter } from 'expo-router';

import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { logEvent } from '@/services/telemetry';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { Screen } from '@/ui/components/Screen';
import { CONTAINER_ICONS, MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

type ScanState = { phase: 'scanning' } | { phase: 'binding'; token: string } | { phase: 'invalid' };

/**
 * Scan tab (issue #10).
 *
 * A known token opens its container immediately. An unknown-but-valid token
 * drops into a picker so the label can be bound. Anything else is reported as
 * "not one of ours" rather than failing silently.
 */
export default function ScanScreen() {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const router = useRouter();
  const { colors } = useTheme();

  const [permission, requestPermission] = useCameraPermissions();
  const [state, setState] = useState<ScanState>({ phase: 'scanning' });
  const [active, setActive] = useState(true);

  // Tab screens stay mounted when you switch away from them, so the camera has
  // to be unmounted explicitly — detaching the scan handler alone leaves the
  // hardware running, draining battery, holding the OS camera indicator on, and
  // blocking other apps from the camera.
  const isFocused = useIsFocused();

  const containers = useInventoryQuery(() => repos.containers.listAllWithSpace(), 'all-containers');

  // Re-arm decoding on focus so returning to the tab starts a fresh scan.
  useFocusEffect(
    useCallback(() => {
      setActive(true);
      setState({ phase: 'scanning' });
      return () => setActive(false);
    }, []),
  );

  async function onScanned(raw: string) {
    if (!active || state.phase !== 'scanning') return;
    setActive(false);

    const outcome = await repos.qr.resolveScan(raw);

    if (outcome.kind === 'bound') {
      logEvent('qr_scan', { outcome: 'bound' });
      router.push(`/container/${outcome.container.id}`);
      return;
    }

    if (outcome.kind === 'unknown') {
      logEvent('qr_scan', { outcome: 'unknown' });
      setState({ phase: 'binding', token: outcome.token });
      return;
    }

    logEvent('qr_scan', { outcome: 'invalid' });
    setState({ phase: 'invalid' });
  }

  async function bindTo(containerId: string, containerLabel: string) {
    if (state.phase !== 'binding') return;
    const token = state.token;

    const existing = await repos.qr.getByContainer(containerId);

    const doBind = async () => {
      await repos.qr.bind(token, containerId);
      logEvent('qr_bound');
      invalidate();
      router.push(`/container/${containerId}`);
      setState({ phase: 'scanning' });
      setActive(true);
    };

    // Replacing a container's existing label is destructive to a printed
    // sticker, so it needs explicit confirmation (issue #10).
    if (existing) {
      Alert.alert(
        strings.scan.rebindTitle,
        `${containerLabel} already has a label. The old sticker will stop working.`,
        [
          { text: strings.common.cancel, style: 'cancel' },
          { text: 'Replace', style: 'destructive', onPress: doBind },
        ],
      );
      return;
    }

    await doBind();
  }

  function rescan() {
    setState({ phase: 'scanning' });
    setActive(true);
  }

  if (!permission) {
    return <Screen edges={['left', 'right']} />;
  }

  if (!permission.granted) {
    const permanentlyDenied = !permission.canAskAgain;
    return (
      <Screen edges={['left', 'right']}>
        <EmptyState
          icon="📷"
          title={
            permanentlyDenied
              ? strings.permissions.cameraDeniedTitle
              : strings.permissions.cameraRationaleTitle
          }
          body={
            permanentlyDenied
              ? strings.permissions.cameraDeniedBody
              : strings.permissions.cameraRationaleBody
          }
          actionLabel={
            permanentlyDenied ? strings.permissions.openSettings : strings.permissions.grant
          }
          onAction={() => {
            if (permanentlyDenied) {
              void Linking.openSettings();
            } else {
              void requestPermission();
            }
          }}
          secondaryActionLabel="Browse spaces instead"
          onSecondaryAction={() => router.push('/')}
        />
      </Screen>
    );
  }

  if (state.phase === 'binding') {
    const list = containers.data ?? [];

    return (
      <Screen edges={['left', 'right']}>
        <FlatList
          data={list}
          keyExtractor={(container) => container.id}
          contentContainerStyle={styles.list}
          ListHeaderComponent={
            <View style={styles.bindHeader}>
              <Text style={[styles.bindTitle, { color: colors.text }]} accessibilityRole="header">
                {strings.scan.unknownTitle}
              </Text>
              <Text style={[styles.bindBody, { color: colors.textMuted }]}>
                {strings.scan.unknownBody}
              </Text>
            </View>
          }
          renderItem={({ item }) => {
            const label = item.name ?? item.shortCode;
            return (
              <Pressable
                onPress={() => bindTo(item.id, label)}
                accessibilityRole="button"
                accessibilityLabel={`Link this label to ${label} in ${item.spaceName}`}
                style={({ pressed }) => [
                  styles.row,
                  {
                    backgroundColor: colors.surface,
                    borderColor: colors.border,
                    opacity: pressed ? 0.8 : 1,
                  },
                ]}
              >
                <Text style={styles.rowGlyph}>
                  {CONTAINER_ICONS[item.visualType] ?? CONTAINER_ICONS.other}
                </Text>
                <View style={styles.rowBody}>
                  <Text style={[styles.rowTitle, { color: colors.text }]}>{label}</Text>
                  <Text style={[styles.rowMeta, { color: colors.textMuted }]}>
                    {item.spaceName} · {item.shortCode}
                  </Text>
                </View>
              </Pressable>
            );
          }}
          ListEmptyComponent={
            <EmptyState
              icon="📦"
              title="No containers yet"
              body="Create a container first, then scan this label again to link it."
              actionLabel="Go to spaces"
              onAction={() => router.push('/')}
            />
          }
          ListFooterComponent={
            <View style={styles.footer}>
              <Button label={strings.common.cancel} variant="ghost" fullWidth onPress={rescan} />
            </View>
          }
        />
      </Screen>
    );
  }

  if (state.phase === 'invalid') {
    return (
      <Screen edges={['left', 'right']}>
        <EmptyState
          icon="❓"
          title={strings.scan.invalidTitle}
          body={strings.scan.invalidBody}
          actionLabel={strings.scan.scanAgain}
          onAction={rescan}
        />
      </Screen>
    );
  }

  return (
    <View style={styles.container}>
      {isFocused ? (
        <CameraView
          style={StyleSheet.absoluteFill}
          facing="back"
          barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
          onBarcodeScanned={active ? ({ data }) => void onScanned(data) : undefined}
        />
      ) : null}
      <View style={styles.scanOverlay} pointerEvents="none">
        <View style={styles.reticle} />
        <Text style={styles.scanHint}>{strings.scan.hint}</Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  scanOverlay: {
    position: 'absolute',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.xl,
  },
  reticle: {
    width: 240,
    height: 240,
    borderRadius: radius.lg,
    borderWidth: 3,
    borderColor: 'rgba(255,255,255,0.9)',
  },
  scanHint: {
    color: '#FFF',
    fontSize: 15,
    textAlign: 'center',
    paddingHorizontal: spacing.xl,
  },
  list: {
    padding: spacing.lg,
    gap: spacing.sm,
  },
  bindHeader: {
    gap: spacing.xs,
    marginBottom: spacing.md,
  },
  bindTitle: {
    fontSize: 22,
    fontWeight: '800',
  },
  bindBody: {
    fontSize: 15,
    lineHeight: 21,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    padding: spacing.md,
    borderRadius: radius.lg,
    borderWidth: 1,
    minHeight: MIN_TOUCH_TARGET,
  },
  rowGlyph: {
    fontSize: 24,
  },
  rowBody: {
    flex: 1,
    gap: 2,
  },
  rowTitle: {
    fontSize: 16,
    fontWeight: '700',
  },
  rowMeta: {
    fontSize: 14,
  },
  footer: {
    paddingTop: spacing.md,
  },
});
