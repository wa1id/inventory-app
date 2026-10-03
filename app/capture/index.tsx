import { useCallback, useEffect, useRef, useState } from 'react';
import { BackHandler, StyleSheet, View } from 'react-native';
import { CameraView, useCameraPermissions, type FlashMode } from 'expo-camera';
import * as ImagePicker from 'expo-image-picker';
import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaView } from 'react-native-safe-area-context';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useToast } from '@/providers/ToastProvider';
import { recognizeItem } from '@/services/ai/recognition';
import { captureFastItem } from '@/services/capture/fastCapture';
import { deleteStoredPhotos, hasRoomForPhoto, storeItemPhoto } from '@/services/capture/imageStore';
import { logError, logEvent } from '@/services/telemetry';
import type { PlaceLike } from '@/ui/a11y';
import {
  CameraNotice,
  DoneButton,
  IntoPill,
  LastShot,
  Reticle,
  Shutter,
  ShutterFlash,
  SideSpacer,
} from '@/ui/capture/CameraChrome';
import { fastStatus, isPermissionError, leaveCamera } from '@/ui/capture/captureFlow';
import { AppText } from '@/ui/components/AppText';
import { CameraPermission } from '@/ui/components/CameraPermission';
import { IconButton } from '@/ui/components/IconButton';
import { StatusPill } from '@/ui/components/StatusPill';
import { TapToFocusLayer } from '@/ui/components/TapToFocusLayer';
import { SegmentedControl } from '@/ui/components/pickers/SegmentedControl';
import { haptics } from '@/ui/haptics';
import type { PhotoResult } from '@/ui/navigation';
import { abandonResult, deliverResult } from '@/ui/routeResult';
import { camera, space } from '@/ui/theme';

type CaptureMode = 'single' | 'fast';

/**
 * Photograph one thing (single) or many in a row (fast, Quick Snap) without
 * waiting on anything (issue #6).
 *
 * Permission is requested only once the user has chosen to take a photo, so the
 * system prompt always arrives with context. Every denial path keeps manual
 * entry one tap away — a camera problem must never block adding an item.
 *
 * The camera mechanics (the preview and tap-to-focus frame, continuous
 * autofocus, the capture options, the fast pipeline's order and the replace
 * to review) are tuned for capture speed and reliability; change them
 * deliberately. The chrome lives in `CameraChrome.tsx`.
 *
 * Opened with `request` (the Add sheet's photo), it is a single-photo camera
 * that hands the stored photo back and closes, so the typed name is still
 * there afterwards.
 */
export default function CaptureScreen() {
  const {
    containerId,
    mode: initialMode,
    since,
    request,
  } = useLocalSearchParams<{
    containerId: string;
    mode?: CaptureMode;
    /** Carried through "keep shooting" so a resumed session reviews as one. */
    since?: string;
    /** Set by a screen waiting for one photo (`routeResult`). */
    request?: string;
  }>();
  const router = useRouter();
  const toast = useToast();

  const repos = useRepositories();
  const { invalidate } = useDatabase();

  const cameraRef = useRef<CameraView>(null);
  const [permission, requestPermission] = useCameraPermissions();
  const [flash, setFlash] = useState<FlashMode>('off');
  const [processing, setProcessing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Context-aware default: the drop zone is for clearing a shelf, a container
  // is usually one deliberate thing, so each entry point opens in the mode that
  // matches the job rather than making you switch every time. A camera opened
  // for one photo is always single.
  const [mode, setMode] = useState<CaptureMode>(
    initialMode === 'fast' && !request ? 'fast' : 'single',
  );
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
  // The same moment as `shutterBusy`, for drawing only: an ignored tap shows.
  const [shooting, setShooting] = useState(false);
  // The newest fast-mode photo, for the last-shot tile and the shutter flash.
  const [lastShot, setLastShot] = useState<string | null>(null);
  // Single mode: `processing` turns on only once the photo is back, so this
  // guard stops a quick second tap from taking two photos and replacing twice.
  const takingRef = useRef(false);
  // The library picker is open: a second tap would ask for another one, and
  // its refusal read as "That photo could not be opened."
  const pickingRef = useRef(false);
  // The camera is on its way out (✕, Android back, Done, Type it instead) or
  // gone. Leaving happens once, and a photo still being saved then neither
  // navigates (it would replace the screen the person went back to, or the
  // Add sheet that was waiting for it) nor stays on the phone.
  const closedRef = useRef(false);
  // Everything created from the first fast shutter press on belongs to this
  // session; the review screen selects by creation time because rows keep
  // landing after the camera has unmounted. Stamped in the handler, not during
  // render, so the component stays pure.
  const sessionStart = useRef<number | null>(since ? Number(since) : null);

  // Where the photos go, for the "Into" pill. Not a reason to hold the camera
  // up: the pill simply appears once this has loaded.
  const into = useInventoryQuery<PlaceLike | null>(async () => {
    if (containerId === DROP_ZONE_CONTAINER_ID) return null;
    const container = await repos.containers.getById(containerId);
    if (!container) return null;
    const home = await repos.spaces.getById(container.spaceId);
    if (!home) return null;
    return {
      containerId: container.id,
      containerName: container.name,
      containerShortCode: container.shortCode,
      spaceId: home.id,
      spaceName: home.name,
      spaceColor: home.color,
    };
  }, `capture-into:${containerId}`);

  // Closing without a photo answers the waiting screen with nothing.
  useEffect(() => () => abandonResult(request), [request]);
  useEffect(() => {
    closedRef.current = false;
    return () => {
      closedRef.current = true;
    };
  }, []);

  /** Over the camera as a notice; on the permission screen, where there is none, as a toast. */
  function report(message: string) {
    if (permission?.granted) setError(message);
    else toast.show({ message, tone: 'error' });
  }

  function continueManually() {
    if (closedRef.current) return;
    closedRef.current = true;
    // The waiting screen is the typing: closing the camera is the way back to it.
    if (request) {
      router.back();
      return;
    }
    router.replace(`/item/new?containerId=${containerId}`);
  }

  async function handleCaptured(uri: string, source: 'camera' | 'library') {
    // Closed while the shutter was still taking it: nothing to save it for.
    if (closedRef.current) return;
    if (!hasRoomForPhoto()) {
      report(strings.capture.noRoom);
      return;
    }

    setProcessing(true);
    setError(null);

    try {
      const stored = await storeItemPhoto(uri);
      logEvent('photo_captured', { source, byteSize: stored.byteSize });

      // Closed while the photo was being saved: nobody will use it now.
      if (closedRef.current) {
        deleteStoredPhotos([stored.uri, stored.thumbUri]);
        return;
      }
      closedRef.current = true;

      // Opened for one photo: hand it back and close. Nobody waiting any more
      // (the opener has gone) falls through to a new item with this photo, so
      // the photo is never thrown away.
      if (request && deliverResult<PhotoResult>(request, stored)) {
        router.back();
        return;
      }

      // Dimensions and size travel with the URI so the item row records what
      // was actually stored rather than re-reading the file later.
      const params = new URLSearchParams({
        containerId,
        photoUri: stored.uri,
        photoThumbUri: stored.thumbUri,
        photoWidth: String(stored.width),
        photoHeight: String(stored.height),
      });
      if (stored.byteSize !== null) params.set('photoBytes', String(stored.byteSize));

      router.replace(`/item/new?${params.toString()}`);
    } catch {
      logError('photo_capture_failed', { source });
      // Nothing to say to someone who has already closed the camera.
      if (closedRef.current) return;
      setProcessing(false);
      report(strings.capture.notProcessed);
    }
  }

  async function takePhoto() {
    if (!cameraRef.current || processing || takingRef.current) return;
    takingRef.current = true;
    try {
      const photo = await cameraRef.current.takePictureAsync({ quality: 1, skipProcessing: false });
      if (photo?.uri) await handleCaptured(photo.uri, 'camera');
    } catch {
      setError(strings.capture.noPhoto);
    } finally {
      takingRef.current = false;
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
    // Before the photo exists, so every row this press creates sorts after it.
    sessionStart.current ??= Date.now();
    if (!hasRoomForPhoto()) {
      setError(strings.capture.noRoom);
      return;
    }

    shutterBusy.current = true;
    setShooting(true);
    let uri: string | undefined;
    try {
      const photo = await cameraRef.current.takePictureAsync({ quality: 1, skipProcessing: false });
      uri = photo?.uri;
    } catch {
      setError(strings.capture.noPhoto);
    } finally {
      shutterBusy.current = false;
      setShooting(false);
    }

    if (!uri) return;

    setCaptured((count) => count + 1);
    setError(null);
    // Feedback for a shot that landed: felt, seen in the flash and the
    // last-shot tile. Fire-and-forget, after the await, so it never holds up
    // the next shot.
    haptics.tap();
    setLastShot(uri);

    void captureFastItem({
      containerId,
      photoUri: uri,
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
    if (closedRef.current) return;
    closedRef.current = true;
    invalidate();
    if (captured === 0) {
      // Back to wherever the camera was opened from.
      // Replacing with `/drop-zone` would now stack a second tab shell.
      router.back();
      return;
    }
    const params = new URLSearchParams({
      containerId,
      // captured > 0 guarantees a shutter press stamped the session start.
      since: String(sessionStart.current ?? Date.now()),
      expected: String(captured),
    });
    router.replace(`/capture/review?${params.toString()}`);
  }

  /** ✕ and Android back: a fast set with shots always ends on its review. */
  function close() {
    if (closedRef.current) return;
    if (leaveCamera(mode, captured) === 'review') {
      finishFast();
      return;
    }
    // Once: a second tap during the dismissal would go back past the origin.
    closedRef.current = true;
    router.back();
  }

  // Android back behaves like ✕. The handler is refreshed after every render
  // so it always sees the current mode and count.
  const closeRef = useRef(close);
  useEffect(() => {
    closeRef.current = close;
  });
  useFocusEffect(
    useCallback(() => {
      const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
        closeRef.current();
        return true;
      });
      return () => subscription.remove();
    }, []),
  );

  async function pickFromLibrary() {
    if (processing || pickingRef.current) return;
    pickingRef.current = true;
    let result: ImagePicker.ImagePickerResult;
    try {
      result = await ImagePicker.launchImageLibraryAsync({
        mediaTypes: ['images'],
        quality: 1,
        allowsMultipleSelection: false,
      });
    } catch (cause) {
      // Caught so a failing picker never rejects unhandled.
      report(
        isPermissionError(cause)
          ? strings.permissions.libraryDeniedBody
          : strings.capture.libraryFailed,
      );
      return;
    } finally {
      pickingRef.current = false;
    }

    if (result.canceled) return;
    const asset = result.assets[0];
    if (asset) await handleCaptured(asset.uri, 'library');
  }

  // Rationale shown immediately before the first camera prompt (issue #12).
  // Black, with light status text, while the permission is still being read.
  if (!permission?.granted) {
    return (
      <>
        {permission === null ? <StatusBar style="light" /> : null}
        <CameraPermission
          purpose="capture"
          permission={permission}
          requestPermission={requestPermission}
          onManual={request ? undefined : continueManually}
          onLibrary={() => void pickFromLibrary()}
          onCancel={close}
          closeTestID="capture-close"
        />
      </>
    );
  }

  const fast = mode === 'fast';
  // Once a set has a shot, it is finished with Done, never by switching mode.
  const locked = fast && captured > 0;
  const status = fastStatus({ captured, completed, recognized });
  // "Type it instead" never lets a fast set skip its review.
  const typeInstead = !request && !locked;

  return (
    <View style={styles.container}>
      {/* The camera is black whatever the scheme: dark status text would vanish. */}
      <StatusBar style="light" />
      <CameraView
        ref={cameraRef}
        style={StyleSheet.absoluteFill}
        facing="back"
        flash={flash}
        // Continuous AF. 'on' would lock after a single shot (issue #44).
        autofocus="off"
        // A camera that cannot start shows an error, never a silent black screen.
        onMountError={() => setError(strings.capture.didNotStart)}
      />
      <TapToFocusLayer
        onFocus={(point) => {
          void cameraRef.current?.focusAsync(point);
        }}
      />

      <Reticle />
      <ShutterFlash trigger={lastShot} />

      <SafeAreaView style={styles.overlay} pointerEvents="box-none">
        <View style={styles.topRow} pointerEvents="box-none">
          <IconButton
            icon="close"
            variant="camera"
            accessibilityLabel={strings.capture.close}
            onPress={close}
            testID="capture-close"
          />
          <View style={styles.intoSlot} pointerEvents="box-none">
            <IntoPill containerId={containerId} place={into.data} />
          </View>
          {/* The glyph shows the state the flash is in now, not the one a tap would choose. */}
          <IconButton
            icon={flash === 'on' ? 'flash' : 'flashOff'}
            variant="camera"
            selected={flash === 'on'}
            accessibilityLabel={strings.capture.flash(flash === 'on')}
            onPress={() => setFlash((current) => (current === 'off' ? 'on' : 'off'))}
            testID="capture-flash"
          />
        </View>

        <View style={styles.bottomStack} pointerEvents="box-none">
          {error ? (
            <CameraNotice
              message={error}
              live="assertive"
              action={
                typeInstead
                  ? {
                      label: strings.capture.manual,
                      onPress: continueManually,
                      testID: 'capture-error-manual',
                    }
                  : undefined
              }
              testID="capture-error"
            />
          ) : null}

          {dropped > 0 ? (
            <CameraNotice
              message={strings.capture.failedSome(dropped)}
              live="polite"
              testID="capture-dropped"
            />
          ) : null}

          {fast && captured > 0 ? (
            <View pointerEvents="none">
              <StatusPill
                icon={status.settled ? 'check' : undefined}
                text={status.text}
                live
                testID="capture-status"
              />
            </View>
          ) : null}

          {request ? null : (
            <View style={styles.modes}>
              <SegmentedControl
                tone="camera"
                options={[
                  {
                    value: 'single',
                    label: strings.capture.modeSingle,
                    icon: 'camera',
                    testID: 'capture-mode-single',
                  },
                  {
                    value: 'fast',
                    label: strings.capture.modeFast,
                    icon: 'layers',
                    testID: 'capture-mode-fast',
                  },
                ]}
                value={mode}
                onChange={setMode}
                accessibilityLabel={strings.capture.modeLabel}
                // Also while a single photo is being saved: its hand-over to the
                // Add sheet would otherwise carry off a fast set begun meanwhile.
                disabled={locked || processing}
                accessibilityHint={locked ? strings.capture.finishSetFirst : undefined}
              />
            </View>
          )}

          <View style={styles.shutterRow} pointerEvents="box-none">
            <View style={[styles.side, styles.sideStart]} pointerEvents="box-none">
              {fast ? (
                <LastShot uri={lastShot} count={captured} />
              ) : (
                <IconButton
                  icon="gallery"
                  variant="camera"
                  accessibilityLabel={strings.capture.library}
                  onPress={() => void pickFromLibrary()}
                  disabled={processing}
                  testID="capture-library"
                />
              )}
            </View>

            <Shutter
              onPress={() => void (fast ? takeFastPhoto() : takePhoto())}
              busy={!fast && processing}
              dimmed={fast && shooting}
            />

            <View style={[styles.side, styles.sideEnd]} pointerEvents="box-none">
              {fast ? (
                <DoneButton count={captured} onPress={finishFast} />
              ) : request ? (
                <SideSpacer />
              ) : (
                <IconButton
                  icon="keyboard"
                  variant="camera"
                  accessibilityLabel={strings.capture.manual}
                  onPress={continueManually}
                  testID="capture-manual"
                />
              )}
            </View>
          </View>

          <View pointerEvents="none">
            <AppText variant="caption" tone="camera" center style={styles.hint}>
              {fast
                ? strings.capture.fastHint
                : processing
                  ? strings.capture.saving
                  : strings.capture.singleHint}
            </AppText>
          </View>
        </View>
      </SafeAreaView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: camera.bg,
  },
  overlay: {
    flex: 1,
    justifyContent: 'space-between',
  },
  topRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    paddingHorizontal: space.sm,
    paddingTop: space.sm,
  },
  intoSlot: {
    flex: 1,
    alignItems: 'center',
  },
  bottomStack: {
    paddingHorizontal: space.lg,
    paddingBottom: space.md,
    gap: space.md,
  },
  modes: {
    alignSelf: 'center',
    width: '100%',
    maxWidth: 320,
    // 16 pt above the shutter row, so a thumb aiming for the shutter does not switch mode.
    marginBottom: space.xs,
  },
  shutterRow: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  // Equal sides keep the shutter centred whatever sits beside it.
  side: {
    flex: 1,
  },
  sideStart: {
    alignItems: 'flex-start',
  },
  sideEnd: {
    alignItems: 'flex-end',
  },
  hint: {
    opacity: 0.85,
  },
});
