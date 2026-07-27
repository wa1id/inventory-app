import { useRef, useState } from 'react';
import { ActivityIndicator, Linking, Pressable, StyleSheet, Text, View } from 'react-native';
import { CameraView, useCameraPermissions, type FlashMode } from 'expo-camera';
import * as ImagePicker from 'expo-image-picker';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { SafeAreaView } from 'react-native-safe-area-context';

import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { recognizeItem } from '@/services/ai/recognition';
import { captureFastItem } from '@/services/capture/fastCapture';
import { hasRoomForPhoto, storeItemPhoto } from '@/services/capture/imageStore';
import { logError, logEvent } from '@/services/telemetry';
import { Button } from '@/ui/components/Button';
import { MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

type CaptureMode = 'single' | 'fast';

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

  const repos = useRepositories();
  const { invalidate } = useDatabase();

  const cameraRef = useRef<CameraView>(null);
  const [permission, requestPermission] = useCameraPermissions();
  const [flash, setFlash] = useState<FlashMode>('off');
  const [processing, setProcessing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [mode, setMode] = useState<CaptureMode>('single');
  // Fast-mode tallies, kept apart on purpose. `captured` counts shutter presses
  // that produced a row, `completed` how many have finished the pipeline, and
  // `recognized` how many of those came back with a usable name — reporting
  // completions as identifications would claim work the AI did not do.
  const [captured, setCaptured] = useState(0);
  const [completed, setCompleted] = useState(0);
  const [recognized, setRecognized] = useState(0);
  const [dropped, setDropped] = useState(0);
  // Guards the camera hardware only. The rest of the pipeline deliberately
  // runs unguarded so the next shot never waits on the previous one.
  const shutterBusy = useRef(false);

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

  /**
   * Fast mode: one tap per item, no form in between.
   *
   * The await ends at the shutter, not at the saved item — everything after
   * that runs in the background so the camera is ready for the next thing on
   * the shelf immediately. Each photo becomes a real row before recognition is
   * attempted, so leaving early or losing the app never loses the item.
   */
  async function takeFastPhoto() {
    if (!cameraRef.current || shutterBusy.current) return;
    if (!hasRoomForPhoto()) {
      setError(
        'There is not enough free space to save a photo. Free some space, or continue without one.',
      );
      return;
    }

    shutterBusy.current = true;
    let uri: string | undefined;
    try {
      const photo = await cameraRef.current.takePictureAsync({ quality: 1, skipProcessing: false });
      uri = photo?.uri;
    } catch {
      setError('The camera did not return a photo. Try again, or continue without one.');
    } finally {
      shutterBusy.current = false;
    }

    if (!uri) return;

    setCaptured((count) => count + 1);
    setError(null);

    void captureFastItem({
      containerId,
      photoUri: uri,
      names: { pending: strings.capture.pendingName, fallback: strings.capture.fallbackName },
      deps: {
        storePhoto: storeItemPhoto,
        createItem: (draft) => repos.items.create(draft),
        updateItem: (id, input) => repos.items.update(id, input),
        recognize: (imageUri) => recognizeItem({ imageUri }),
      },
    })
      .then((outcome) => {
        setCompleted((count) => count + 1);
        logEvent('photo_captured', { source: 'camera', mode: 'fast' });
        if (outcome.status === 'recognized') {
          setRecognized((count) => count + 1);
        } else {
          logEvent('recognition_unusable', { reason: outcome.reason });
        }
        // Keeps the container list behind the camera honest as rows land.
        invalidate();
      })
      .catch(() => {
        logError('fast_capture_failed', { source: 'camera' });
        setCaptured((count) => Math.max(0, count - 1));
        setDropped((count) => count + 1);
      });
  }

  function finishFast() {
    invalidate();
    router.replace(`/container/${containerId}`);
  }

  const pending = captured - completed;
  const unnamed = completed - recognized;
  const fastStatus =
    pending > 0
      ? strings.capture.identifying(pending)
      : unnamed === 0
        ? strings.capture.identified(recognized)
        : recognized === 0
          ? strings.capture.savedUnnamed(unnamed)
          : strings.capture.identifiedPartly(recognized, unnamed);

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

          {mode === 'fast' && captured > 0 ? (
            <View style={styles.statusPill} accessibilityLiveRegion="polite">
              <Text style={styles.statusText}>{fastStatus}</Text>
            </View>
          ) : null}

          {dropped > 0 ? (
            <Text style={styles.dropped} accessibilityLiveRegion="polite">
              {strings.capture.failedSome(dropped)}
            </Text>
          ) : null}

          <View
            style={styles.modeRow}
            accessibilityRole="radiogroup"
            accessibilityLabel={strings.capture.modeLabel}
          >
            {(['single', 'fast'] as const).map((option) => {
              const selected = option === mode;
              return (
                <Pressable
                  key={option}
                  onPress={() => setMode(option)}
                  accessibilityRole="radio"
                  accessibilityState={{ selected }}
                  accessibilityLabel={
                    option === 'single' ? strings.capture.modeSingle : strings.capture.modeFast
                  }
                  testID={`capture-mode-${option}`}
                  style={[styles.modeChip, selected && styles.modeChipSelected]}
                >
                  <Text style={[styles.modeText, selected && styles.modeTextSelected]}>
                    {option === 'single' ? strings.capture.modeSingle : strings.capture.modeFast}
                  </Text>
                </Pressable>
              );
            })}
          </View>

          <View style={styles.shutterRow}>
            {mode === 'single' ? (
              <Pressable
                onPress={pickFromLibrary}
                accessibilityRole="button"
                accessibilityLabel="Import from photo library"
                style={styles.circleButton}
                disabled={processing}
              >
                <Text style={styles.circleGlyph}>🖼️</Text>
              </Pressable>
            ) : (
              <View style={styles.circleButton} />
            )}

            <Pressable
              onPress={mode === 'fast' ? takeFastPhoto : takePhoto}
              accessibilityRole="button"
              accessibilityLabel="Take photo"
              accessibilityState={{
                busy: mode === 'single' && processing,
                disabled: mode === 'single' && processing,
              }}
              disabled={mode === 'single' && processing}
              testID="capture-shutter"
              style={styles.shutter}
            >
              {mode === 'single' && processing ? (
                <ActivityIndicator color="#111" />
              ) : (
                <View style={styles.shutterInner} />
              )}
            </Pressable>

            {mode === 'fast' ? (
              <Pressable
                onPress={finishFast}
                accessibilityRole="button"
                accessibilityLabel={
                  captured > 0 ? strings.capture.doneCount(captured) : strings.capture.done
                }
                testID="capture-done"
                style={[styles.doneButton, captured === 0 && styles.doneButtonIdle]}
              >
                <Text style={styles.doneText}>
                  {captured > 0 ? strings.capture.doneCount(captured) : strings.capture.done}
                </Text>
              </Pressable>
            ) : (
              <Pressable
                onPress={continueManually}
                accessibilityRole="button"
                accessibilityLabel={strings.permissions.continueManually}
                style={styles.circleButton}
              >
                <Text style={styles.circleGlyph}>✍️</Text>
              </Pressable>
            )}
          </View>

          <Text style={styles.hint}>
            {mode === 'fast'
              ? strings.capture.fastHint
              : processing
                ? strings.capture.saving
                : strings.capture.singleHint}
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
  modeRow: {
    flexDirection: 'row',
    alignSelf: 'center',
    gap: spacing.xs,
    padding: spacing.xs,
    borderRadius: radius.pill,
    backgroundColor: 'rgba(0,0,0,0.55)',
  },
  modeChip: {
    minHeight: MIN_TOUCH_TARGET - spacing.md,
    paddingHorizontal: spacing.lg,
    justifyContent: 'center',
    borderRadius: radius.pill,
  },
  modeChipSelected: {
    backgroundColor: 'rgba(255,255,255,0.16)',
  },
  modeText: {
    color: 'rgba(255,255,255,0.7)',
    fontSize: 15,
    fontWeight: '600',
  },
  modeTextSelected: {
    color: '#FFF',
    fontWeight: '700',
  },
  statusPill: {
    alignSelf: 'center',
    paddingHorizontal: spacing.lg,
    paddingVertical: spacing.sm,
    borderRadius: radius.pill,
    backgroundColor: 'rgba(0,0,0,0.7)',
  },
  statusText: {
    color: '#FFF',
    fontSize: 15,
    fontWeight: '700',
  },
  dropped: {
    color: '#FFC9BC',
    fontSize: 14,
    textAlign: 'center',
  },
  doneButton: {
    minHeight: MIN_TOUCH_TARGET,
    minWidth: 96,
    paddingHorizontal: spacing.lg,
    borderRadius: radius.pill,
    backgroundColor: '#FFF',
    alignItems: 'center',
    justifyContent: 'center',
  },
  doneButtonIdle: {
    backgroundColor: 'rgba(255,255,255,0.55)',
  },
  doneText: {
    color: '#111',
    fontSize: 16,
    fontWeight: '700',
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
