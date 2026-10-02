import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import {
  AccessibilityInfo,
  ActivityIndicator,
  BackHandler,
  Platform,
  Pressable,
  StyleSheet,
  View,
} from 'react-native';
import { router, useFocusEffect, useNavigation } from 'expo-router';
import type { BottomTabNavigationProp } from 'expo-router/js-tabs';
import type { ParamListBase } from 'expo-router/react-navigation';

import { useDelayedFlag } from '@/hooks/useDelayedFlag';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import type { ScanOutcome } from '@/repositories/qr';
import { logError, logEvent } from '@/services/telemetry';
import { AppText } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { Icon, type IconName } from '@/ui/components/Icon';
import { PlacePicker, type PickedPlace } from '@/ui/components/PlacePicker';
import { rippleFor, useFocusRing, usesRipple } from '@/ui/components/PressFeedback';
import { QrScanner } from '@/ui/components/QrScanner';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { describeError } from '@/ui/errors';
import { haptics } from '@/ui/haptics';
import { delay } from '@/ui/motion';
import { openContainer } from '@/ui/navigation';
import { CONTENT_MAX_WIDTH, GUTTER, camera, radius, space, useTheme } from '@/ui/theme';

/** The camera, or the typed-code list that stands in for it (the camera is off meanwhile). */
type Phase = 'camera' | 'code';

/** What happened to the last label the camera read. */
type Result =
  | { kind: 'idle' }
  /** Looking it up (over the network when paired); the camera stays on, paused. */
  | { kind: 'opening' }
  | { kind: 'notOurs' }
  | { kind: 'failed'; cause: unknown };

interface PanelProps {
  tone: 'hint' | 'busy' | 'error';
  title?: string;
  message: string;
  children?: ReactNode;
}

/**
 * A notice over the bottom of the picture, above the tab bar: white on the
 * dark chip, so it reads over any scene. Errors get the coloured edge rather
 * than coloured text (signal on a chip over a bright scene is too faint).
 */
function ScanPanel({ tone, title, message, children }: PanelProps) {
  const announcement = title ? `${title}. ${message}` : message;

  // Android reads the live region; iOS needs telling. The standing hint is not news.
  useEffect(() => {
    if (Platform.OS === 'ios' && tone !== 'hint') {
      AccessibilityInfo.announceForAccessibility(announcement);
    }
  }, [announcement, tone]);

  return (
    <View pointerEvents="box-none" style={styles.panelWrap}>
      <View
        accessibilityLiveRegion={
          tone === 'error' ? 'assertive' : tone === 'busy' ? 'polite' : 'none'
        }
        style={[
          styles.panel,
          tone === 'error' ? styles.errorPad : null,
          { backgroundColor: camera.chip },
        ]}
      >
        {tone === 'error' ? (
          <View style={[styles.errorBar, { backgroundColor: camera.errorBar }]} />
        ) : null}
        <View style={styles.panelText}>
          {tone === 'busy' ? <ActivityIndicator color={camera.ink} /> : null}
          <View style={styles.panelWords}>
            {title ? (
              <AppText variant="heading" tone="camera">
                {title}
              </AppText>
            ) : null}
            <AppText variant="body" tone="camera">
              {message}
            </AppText>
          </View>
        </View>
        {children ? <View style={styles.panelActions}>{children}</View> : null}
      </View>
    </View>
  );
}

interface CameraButtonProps {
  label: string;
  icon?: IconName;
  onPress: () => void;
  testID: string;
}

/**
 * A small outlined white button for use over the camera (the camera-styled
 * `Button sm`): the regular buttons are drawn for the plaster wall. Its
 * keyboard focus ring is white too, since ink is dark on the dark chip.
 */
function CameraButton({ label, icon, onPress, testID }: CameraButtonProps) {
  const { colors } = useTheme();
  const focus = useFocusRing();
  return (
    <Pressable
      onPress={onPress}
      onFocus={focus.onFocus}
      onBlur={focus.onBlur}
      hitSlop={4}
      accessibilityRole="button"
      accessibilityLabel={label}
      testID={testID}
      android_ripple={rippleFor(colors, { color: camera.chipPressed })}
      style={({ pressed }) => [
        styles.cameraButton,
        { borderColor: camera.ink },
        pressed && !usesRipple ? { backgroundColor: camera.chipPressed } : null,
        focus.ringStyle ? [focus.ringStyle, { outlineColor: camera.ink }] : null,
      ]}
    >
      {icon ? <Icon name={icon} size={18} color={camera.ink} /> : null}
      <AppText variant="label" tone="camera" style={styles.shrink}>
        {label}
      </AppText>
    </Pressable>
  );
}

/**
 * Scan tab: "What's in this box?" (issue #10).
 *
 * Point the camera at a label and its container opens. A label this app made
 * but never linked goes to `/c/<token>`, the one place where labels are
 * linked, so the Scan tab and the iPhone Camera behave the same. Anything else
 * says plainly that it is not one of ours, and a failed lookup says what went
 * wrong instead of leaving the scanner dead.
 *
 * `QrScanner` owns the camera: it runs only while this tab is in front (a tab
 * stays mounted in the background), and it ignores the second and third
 * frames of the same label, so one label opens one container. When a
 * label cannot be read, "Type a code instead" lists the containers to find it
 * by the code written on the box.
 */
export default function ScanScreen() {
  const repos = useRepositories();
  const navigation = useNavigation<BottomTabNavigationProp<ParamListBase>>();
  const [phase, setPhase] = useState<Phase>('camera');
  const [result, setResult] = useState<Result>({ kind: 'idle' });
  const showOpening = useDelayedFlag(result.kind === 'opening', delay.skeleton);

  // Numbers each lookup, so one that finishes after the tab was left (or a
  // newer one started) neither opens a container over another tab nor
  // overwrites what is on screen now.
  const lookupRef = useRef(0);

  // QrScanner hands a code over only after its 250 ms reticle flash, so the
  // person may have switched tabs or opened the typed list in between. A code
  // read then must not start a lookup at all: its `open` closure still thinks
  // the camera is up, so this ref says what is in front now.
  const cameraUpRef = useRef(true);
  useEffect(() => {
    cameraUpRef.current = phase === 'camera';
  }, [phase]);

  // Every visit starts at the camera with nothing in the way; leaving the tab
  // drops a lookup still in flight.
  useFocusEffect(
    useCallback(() => {
      setPhase('camera');
      setResult({ kind: 'idle' });
      return () => {
        lookupRef.current += 1;
      };
    }, []),
  );

  // Re-tapping Scan re-arms the camera: off the code list, past a notice. A
  // lookup in flight is left to finish.
  useEffect(
    () =>
      navigation.addListener('tabPress', () => {
        if (!navigation.isFocused()) return;
        setPhase('camera');
        setResult((current) => (current.kind === 'opening' ? current : { kind: 'idle' }));
      }),
    [navigation],
  );

  // Android back on the code list returns to the camera, as from a sub-screen.
  useFocusEffect(
    useCallback(() => {
      if (phase !== 'code') return;
      const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
        setPhase('camera');
        return true;
      });
      return () => subscription.remove();
    }, [phase]),
  );

  async function open(raw: string) {
    if (!cameraUpRef.current || !navigation.isFocused()) return;
    lookupRef.current += 1;
    const lookup = lookupRef.current;
    setResult({ kind: 'opening' });

    let outcome: ScanOutcome;
    try {
      outcome = await repos.qr.resolveScan(raw);
    } catch (cause) {
      if (lookup !== lookupRef.current) return;
      logError('qr_scan_failed', { errorClass: describeError(cause).kind });
      haptics.error();
      setResult({ kind: 'failed', cause });
      return;
    }
    if (lookup !== lookupRef.current) return;

    if (outcome.kind === 'bound') {
      logEvent('qr_scan', { outcome: 'bound' });
      haptics.success();
      setResult({ kind: 'idle' });
      openContainer(outcome.container.id);
      return;
    }

    if (outcome.kind === 'unknown') {
      logEvent('qr_scan', { outcome: 'unknown' });
      setResult({ kind: 'idle' });
      router.push(`/c/${outcome.token}`);
      return;
    }

    logEvent('qr_scan', { outcome: 'invalid' });
    haptics.error();
    setResult({ kind: 'notOurs' });
  }

  function scanAgain() {
    setResult({ kind: 'idle' });
  }

  function typeCode() {
    // A label still being looked up must not open over the list.
    lookupRef.current += 1;
    setResult({ kind: 'idle' });
    setPhase('code');
  }

  function openTyped(place: PickedPlace) {
    // The list stays as it is under the container; coming back starts at the
    // camera. Once it is opening this tab is no longer in front, so a second
    // tap on the row does not push the container twice.
    if (place.kind === 'container' && navigation.isFocused()) openContainer(place.option.id);
  }

  if (phase === 'code') {
    return (
      <ScreenFrame kind="tabRoot">
        <View style={styles.codeHead}>
          <AppText variant="heading" style={styles.codeTitle}>
            {strings.scan.codeTitle}
          </AppText>
          <Button
            label={strings.scan.backToCamera}
            icon="camera"
            variant="quiet"
            size="sm"
            onPress={() => setPhase('camera')}
            testID="scan-back-to-camera"
            style={styles.backToCamera}
          />
        </View>
        <PlacePicker mode="open" placeholder={strings.scan.codePlaceholder} onPick={openTyped} />
      </ScreenFrame>
    );
  }

  const typeCodeButton = (
    <CameraButton
      label={strings.scan.typeCode}
      icon="keyboard"
      onPress={typeCode}
      testID="scan-type-code"
    />
  );

  let footer: ReactNode;
  if (result.kind === 'notOurs') {
    footer = (
      <ScanPanel tone="error" title={strings.scan.invalidTitle} message={strings.scan.invalidBody}>
        <CameraButton label={strings.scan.scanAgain} onPress={scanAgain} testID="scan-again" />
        {typeCodeButton}
      </ScanPanel>
    );
  } else if (result.kind === 'failed') {
    const described = describeError(result.cause);
    footer = (
      <ScanPanel tone="error" title={described.title} message={described.body}>
        <CameraButton
          label={strings.common.tryAgain}
          icon="refresh"
          onPress={scanAgain}
          testID="scan-try-again"
        />
        {typeCodeButton}
      </ScanPanel>
    );
  } else if (showOpening) {
    footer = <ScanPanel tone="busy" message={strings.scan.opening} />;
  } else {
    footer = (
      <ScanPanel tone="hint" message={strings.scan.hint}>
        {typeCodeButton}
      </ScanPanel>
    );
  }

  return (
    <ScreenFrame kind="camera" testID="scan-camera">
      <QrScanner
        // Off while a notice waits for an answer; "Scan again" turns it back on, re-armed.
        active={result.kind === 'idle' || result.kind === 'opening'}
        title={strings.scan.title}
        onScan={open}
        onManual={typeCode}
        torchTestID="scan-torch"
        footer={footer}
      />
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  panelWrap: {
    position: 'absolute',
    left: 0,
    right: 0,
    // The scene ends at the tab bar, so this sits just above it.
    bottom: space.lg,
    paddingHorizontal: GUTTER,
    alignItems: 'center',
  },
  panel: {
    width: '100%',
    maxWidth: CONTENT_MAX_WIDTH,
    gap: space.md,
    padding: space.lg,
    borderRadius: radius.card,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  // Room for the error edge, so the words keep the same 16 pt from it.
  errorPad: {
    paddingStart: space.lg + 4,
  },
  errorBar: {
    position: 'absolute',
    start: 0,
    top: 0,
    bottom: 0,
    width: 4,
  },
  panelText: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
  },
  panelWords: {
    flexShrink: 1,
    gap: space.xs,
  },
  panelActions: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: space.sm,
  },
  cameraButton: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'flex-start',
    gap: space.sm,
    minHeight: 40,
    paddingHorizontal: space.md,
    paddingVertical: space.sm,
    borderWidth: 1,
    borderRadius: radius.control,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  shrink: {
    flexShrink: 1,
  },
  codeHead: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    columnGap: space.sm,
    rowGap: space.xs,
    paddingTop: space.md,
    paddingHorizontal: GUTTER,
  },
  codeTitle: {
    flexGrow: 1,
    flexShrink: 1,
  },
  backToCamera: {
    // Buttons hold themselves to the start; this one centres on the title row.
    alignSelf: 'center',
    marginEnd: -space.md,
  },
});
