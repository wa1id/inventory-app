import { useCallback, useRef, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { CameraView, useCameraPermissions, type BarcodeScanningResult } from 'expo-camera';
import { useFocusEffect, useIsFocused } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { CameraPermission } from '@/ui/components/CameraPermission';
import { IconButton } from '@/ui/components/IconButton';
import { StatusPill } from '@/ui/components/StatusPill';
import { duration, motionMs, useReducedMotion } from '@/ui/motion';
import { GUTTER, camera, radius, space } from '@/ui/theme';

export interface QrScannerProps {
  /** False while the screen shows something else over the camera (a picker, a code field). */
  active: boolean;
  /** Said at the top: "Scan a label", "Scan the sticker for Tool chest". */
  title: string;
  /**
   * Called once per scan with the raw code. Scanning stays paused afterwards
   * until the screen is focused again or `active` goes false and back to
   * true, so one label held in view opens one container, not three.
   */
  onScan: (raw: string) => void | Promise<void>;
  /** Type the code instead (permission screen and camera failure panel). */
  onManual?: () => void;
  /** Full-screen hosts (linking a sticker) close the camera; the Scan tab has nothing to close. */
  onClose?: () => void;
  torchLabelOn?: string;
  torchLabelOff?: string;
}

/** The reticle's side; its corners flash the camera accent when a code is read. */
const RETICLE = 240;

/**
 * The QR scanner shared by the Scan tab and sticker linking.
 *
 * The camera runs only while the screen is focused and the scanner is active:
 * a tab stays mounted in the background, and a running camera there drains
 * the battery, keeps the OS camera light on and blocks other apps. The scan
 * guard is set synchronously before anything is awaited, so the second and
 * third frames of the same label are ignored rather than pushing the
 * container two more times (capture §13.2).
 */
export function QrScanner({
  active,
  title,
  onScan,
  onManual,
  onClose,
  torchLabelOn,
  torchLabelOff,
}: QrScannerProps) {
  const isFocused = useIsFocused();
  const reduced = useReducedMotion();
  const insets = useSafeAreaInsets();
  const [permission, requestPermission] = useCameraPermissions();
  const [torch, setTorch] = useState(false);
  const [locked, setLocked] = useState(false);
  const [mountFailed, setMountFailed] = useState(false);

  // Each focus, and each time the caller re-activates, is a new "arming"; a
  // scan pauses the arming it happened in.
  const [arming, setArming] = useState(0);
  const [scannedIn, setScannedIn] = useState(-1);
  const scannedRef = useRef(-1);
  const [wasActive, setWasActive] = useState(active);
  if (active !== wasActive) {
    setWasActive(active);
    if (active) setArming((value) => value + 1);
  }

  useFocusEffect(
    useCallback(() => {
      setArming((value) => value + 1);
      return () => setTorch(false);
    }, []),
  );

  const armed = scannedIn !== arming;

  async function handle(result: BarcodeScanningResult) {
    if (scannedRef.current === arming) return;
    scannedRef.current = arming;
    setScannedIn(arming);
    setLocked(true);
    try {
      const wait = motionMs(duration.reticleLock, reduced);
      if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
      await onScan(result.data);
    } finally {
      setLocked(false);
    }
  }

  if (!permission?.granted) {
    return (
      <CameraPermission
        purpose="scan"
        permission={permission}
        requestPermission={requestPermission}
        onManual={onManual}
        onCancel={onClose}
      />
    );
  }

  const torchLabel = torch
    ? (torchLabelOn ?? strings.camera.torchState(true))
    : (torchLabelOff ?? strings.camera.torchState(false));

  return (
    <View style={[styles.fill, { backgroundColor: camera.bg }]}>
      {isFocused && active ? (
        <CameraView
          style={StyleSheet.absoluteFill}
          facing="back"
          barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
          onBarcodeScanned={armed ? (result) => void handle(result) : undefined}
          enableTorch={torch}
          onMountError={() => setMountFailed(true)}
        />
      ) : null}

      <Reticle locked={locked} />

      <View
        pointerEvents="box-none"
        style={[styles.top, { top: insets.top + space.sm, start: insets.left, end: insets.right }]}
      >
        <View style={styles.side}>
          {onClose ? (
            <IconButton
              icon="close"
              variant="camera"
              accessibilityLabel={strings.camera.close}
              onPress={onClose}
              testID="scanner-close"
            />
          ) : null}
        </View>
        <View style={styles.pill}>
          <StatusPill text={title} />
        </View>
        <View style={styles.side}>
          {/* The torch is the first thing to suspect when the camera will not start (R16). */}
          {mountFailed ? null : (
            <IconButton
              icon="torch"
              variant="camera"
              selected={torch}
              accessibilityLabel={torchLabel}
              onPress={() => setTorch((on) => !on)}
              testID="scanner-torch"
            />
          )}
        </View>
      </View>

      {mountFailed ? (
        <View
          style={[styles.panel, { bottom: insets.bottom + space.xl, backgroundColor: camera.chip }]}
          accessibilityLiveRegion="assertive"
        >
          <View style={[styles.errorBar, { backgroundColor: camera.errorBar }]} />
          <AppText variant="body" tone="camera">
            {strings.camera.didNotStartScan}
          </AppText>
          {onManual ? (
            <Button
              label={strings.permissions.typeCodeInstead}
              icon="keyboard"
              variant="secondary"
              onPress={onManual}
              testID="scanner-manual"
            />
          ) : null}
        </View>
      ) : null}
    </View>
  );
}

const CORNERS = ['topLeft', 'topRight', 'bottomLeft', 'bottomRight'] as const;

/** Four corner brackets around where the label should go. Decorative. */
function Reticle({ locked }: { locked: boolean }) {
  const color = locked ? camera.accent : 'rgba(255,255,255,0.85)';
  return (
    <View
      pointerEvents="none"
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={styles.reticleWrap}
    >
      <View style={styles.reticle}>
        {CORNERS.map((corner) => (
          <View key={corner} style={[styles.corner, styles[corner]]}>
            <View style={[styles.armH, { backgroundColor: color }]} />
            <View style={[styles.armV, { backgroundColor: color }]} />
          </View>
        ))}
      </View>
    </View>
  );
}

const ARM = 40;
const THICK = 3;

const styles = StyleSheet.create({
  fill: {
    flex: 1,
  },
  top: {
    position: 'absolute',
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: space.sm,
    gap: space.sm,
  },
  side: {
    width: 48,
  },
  pill: {
    flex: 1,
    alignItems: 'center',
  },
  panel: {
    position: 'absolute',
    left: GUTTER,
    right: GUTTER,
    gap: space.md,
    padding: space.lg,
    paddingStart: space.lg + 4,
    borderRadius: radius.card,
    borderCurve: 'continuous',
    alignItems: 'flex-start',
  },
  errorBar: {
    position: 'absolute',
    start: 0,
    top: 0,
    bottom: 0,
    width: 4,
    borderTopStartRadius: radius.card,
    borderBottomStartRadius: radius.card,
  },
  reticleWrap: {
    position: 'absolute',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    alignItems: 'center',
    justifyContent: 'center',
  },
  reticle: {
    width: RETICLE,
    height: RETICLE,
  },
  corner: {
    position: 'absolute',
    width: ARM,
    height: ARM,
  },
  topLeft: {
    top: 0,
    left: 0,
  },
  topRight: {
    top: 0,
    right: 0,
    transform: [{ scaleX: -1 }],
  },
  bottomLeft: {
    bottom: 0,
    left: 0,
    transform: [{ scaleY: -1 }],
  },
  bottomRight: {
    bottom: 0,
    right: 0,
    transform: [{ scaleX: -1 }, { scaleY: -1 }],
  },
  armH: {
    position: 'absolute',
    top: 0,
    left: 0,
    width: ARM,
    height: THICK,
    borderRadius: THICK / 2,
  },
  armV: {
    position: 'absolute',
    top: 0,
    left: 0,
    width: THICK,
    height: ARM,
    borderRadius: THICK / 2,
  },
});
