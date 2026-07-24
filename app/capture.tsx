import { useRef, useState } from 'react';
import { ActivityIndicator, Linking, Pressable, StyleSheet, Text, View } from 'react-native';
import { CameraView, useCameraPermissions, type FlashMode } from 'expo-camera';
import * as ImagePicker from 'expo-image-picker';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { SafeAreaView } from 'react-native-safe-area-context';

import { strings } from '@/i18n/strings';
import { hasRoomForPhoto, storeItemPhoto } from '@/services/capture/imageStore';
import { logError, logEvent } from '@/services/telemetry';
import { Button } from '@/ui/components/Button';
import { MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

/**
 * Single-item capture (issue #6).
 *
 * Permission is requested only once the user has chosen to take a photo, so the
 * system prompt always arrives with context. Every denial path keeps manual
 * entry one tap away — a camera problem must never block adding an item.
 */
export default function CaptureScreen() {
  const { containerId } = useLocalSearchParams<{ containerId: string }>();
  const router = useRouter();
  const { colors } = useTheme();

  const cameraRef = useRef<CameraView>(null);
  const [permission, requestPermission] = useCameraPermissions();
  const [flash, setFlash] = useState<FlashMode>('off');
  const [processing, setProcessing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function continueManually() {
    router.replace(`/item/new?containerId=${containerId}`);
  }

  async function handleCaptured(uri: string, source: 'camera' | 'library') {
    if (!hasRoomForPhoto()) {
      setError(
        'There is not enough free space to save a photo. Free some space, or continue without one.',
      );
      return;
    }

    setProcessing(true);
    setError(null);

    try {
      const stored = await storeItemPhoto(uri);
      logEvent('photo_captured', { source, byteSize: stored.byteSize });

      // Dimensions and size travel with the URI so the item row records what
      // was actually stored rather than re-reading the file later.
      const params = new URLSearchParams({
        containerId,
        photoUri: stored.uri,
        photoWidth: String(stored.width),
        photoHeight: String(stored.height),
      });
      if (stored.byteSize !== null) params.set('photoBytes', String(stored.byteSize));

      router.replace(`/item/new?${params.toString()}`);
    } catch (cause) {
      logError('photo_capture_failed', { source });
      setProcessing(false);
      setError(
        cause instanceof Error
          ? cause.message
          : 'That photo could not be processed. Try again, or continue without a photo.',
      );
    }
  }

  async function takePhoto() {
    if (!cameraRef.current || processing) return;
    try {
      const photo = await cameraRef.current.takePictureAsync({ quality: 1, skipProcessing: false });
      if (photo?.uri) await handleCaptured(photo.uri, 'camera');
    } catch {
      setError('The camera did not return a photo. Try again, or continue without one.');
    }
  }

  async function pickFromLibrary() {
    const result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ['images'],
      quality: 1,
      allowsMultipleSelection: false,
    });

    if (result.canceled) return;
    const asset = result.assets[0];
    if (asset) await handleCaptured(asset.uri, 'library');
  }

  // Permission not yet resolved.
  if (!permission) {
    return (
      <SafeAreaView style={[styles.fallback, { backgroundColor: colors.background }]}>
        <ActivityIndicator color={colors.primary} />
      </SafeAreaView>
    );
  }

  // Rationale shown immediately before the first camera prompt (issue #12).
  if (!permission.granted) {
    const permanentlyDenied = !permission.canAskAgain;

    return (
      <SafeAreaView style={[styles.fallback, { backgroundColor: colors.background }]}>
        <Text style={styles.glyph}>📸</Text>
        <Text style={[styles.fallbackTitle, { color: colors.text }]} accessibilityRole="header">
          {permanentlyDenied
            ? strings.permissions.cameraDeniedTitle
            : strings.permissions.cameraRationaleTitle}
        </Text>
        <Text style={[styles.fallbackBody, { color: colors.textMuted }]}>
          {permanentlyDenied
            ? strings.permissions.cameraDeniedBody
            : strings.permissions.cameraRationaleBody}
        </Text>

        <View style={styles.fallbackActions}>
          {permanentlyDenied ? (
            <Button
              label={strings.permissions.openSettings}
              fullWidth
              onPress={() => Linking.openSettings()}
            />
          ) : (
            <Button
              label={strings.permissions.grant}
              fullWidth
              onPress={async () => {
                const next = await requestPermission();
                logEvent('permission_result', {
                  permission: 'camera',
                  outcome: next.granted ? 'granted' : 'denied',
                });
              }}
            />
          )}
          <Button
            label="Choose from library instead"
            variant="secondary"
            fullWidth
            onPress={pickFromLibrary}
          />
          <Button
            label={strings.permissions.continueManually}
            variant="ghost"
            fullWidth
            onPress={continueManually}
          />
          <Button
            label={strings.common.cancel}
            variant="ghost"
            fullWidth
            onPress={() => router.back()}
          />
        </View>
      </SafeAreaView>
    );
  }

  return (
    <View style={styles.container}>
      <CameraView ref={cameraRef} style={StyleSheet.absoluteFill} facing="back" flash={flash} />

      <SafeAreaView style={styles.overlay}>
        <View style={styles.topBar}>
          <Pressable
            onPress={() => router.back()}
            accessibilityRole="button"
            accessibilityLabel={strings.common.cancel}
            style={styles.circleButton}
          >
            <Text style={styles.circleGlyph}>✕</Text>
          </Pressable>

          <Pressable
            onPress={() => setFlash((mode) => (mode === 'off' ? 'on' : 'off'))}
            accessibilityRole="button"
            accessibilityLabel={flash === 'off' ? 'Turn flash on' : 'Turn flash off'}
            accessibilityState={{ selected: flash === 'on' }}
            style={styles.circleButton}
          >
            <Text style={styles.circleGlyph}>{flash === 'off' ? '🔦' : '⚡'}</Text>
          </Pressable>
        </View>

        <View style={styles.bottomBar}>
          {error ? (
            <View style={styles.errorBanner} accessibilityLiveRegion="assertive">
              <Text style={styles.errorText}>{error}</Text>
              <Pressable onPress={continueManually} accessibilityRole="button">
                <Text style={styles.errorAction}>{strings.permissions.continueManually}</Text>
              </Pressable>
            </View>
          ) : null}

          <View style={styles.shutterRow}>
            <Pressable
              onPress={pickFromLibrary}
              accessibilityRole="button"
              accessibilityLabel="Import from photo library"
              style={styles.circleButton}
              disabled={processing}
            >
              <Text style={styles.circleGlyph}>🖼️</Text>
            </Pressable>

            <Pressable
              onPress={takePhoto}
              accessibilityRole="button"
              accessibilityLabel="Take photo"
              accessibilityState={{ busy: processing, disabled: processing }}
              disabled={processing}
              style={styles.shutter}
            >
              {processing ? (
                <ActivityIndicator color="#111" />
              ) : (
                <View style={styles.shutterInner} />
              )}
            </Pressable>

            <Pressable
              onPress={continueManually}
              accessibilityRole="button"
              accessibilityLabel={strings.permissions.continueManually}
              style={styles.circleButton}
            >
              <Text style={styles.circleGlyph}>✍️</Text>
            </Pressable>
          </View>

          <Text style={styles.hint}>
            {processing ? 'Saving your photo…' : 'Fill the frame with the item'}
          </Text>
        </View>
      </SafeAreaView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  overlay: {
    flex: 1,
    justifyContent: 'space-between',
  },
  topBar: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    padding: spacing.lg,
  },
  bottomBar: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  shutterRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  circleButton: {
    width: MIN_TOUCH_TARGET,
    height: MIN_TOUCH_TARGET,
    borderRadius: radius.pill,
    backgroundColor: 'rgba(0,0,0,0.55)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  circleGlyph: {
    fontSize: 20,
    color: '#FFF',
  },
  shutter: {
    width: 76,
    height: 76,
    borderRadius: radius.pill,
    backgroundColor: 'rgba(255,255,255,0.9)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  shutterInner: {
    width: 62,
    height: 62,
    borderRadius: radius.pill,
    backgroundColor: '#FFF',
    borderWidth: 2,
    borderColor: '#111',
  },
  hint: {
    color: '#FFF',
    textAlign: 'center',
    fontSize: 14,
  },
  errorBanner: {
    backgroundColor: 'rgba(0,0,0,0.75)',
    borderRadius: radius.md,
    padding: spacing.md,
    gap: spacing.sm,
  },
  errorText: {
    color: '#FFF',
    fontSize: 14,
    lineHeight: 20,
  },
  errorAction: {
    color: '#7FB0FF',
    fontSize: 15,
    fontWeight: '700',
    minHeight: MIN_TOUCH_TARGET,
    textAlignVertical: 'center',
  },
  fallback: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.xl,
    gap: spacing.sm,
  },
  glyph: {
    fontSize: 48,
  },
  fallbackTitle: {
    fontSize: 20,
    fontWeight: '700',
    textAlign: 'center',
  },
  fallbackBody: {
    fontSize: 15,
    lineHeight: 21,
    textAlign: 'center',
  },
  fallbackActions: {
    alignSelf: 'stretch',
    gap: spacing.sm,
    marginTop: spacing.xl,
  },
});
