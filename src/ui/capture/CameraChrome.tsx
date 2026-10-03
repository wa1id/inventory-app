import { useEffect, useState } from 'react';
import {
  AccessibilityInfo,
  ActivityIndicator,
  Animated,
  Image,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { strings } from '@/i18n/strings';
import type { PlaceLike } from '@/ui/a11y';
import { intoA11y } from '@/ui/capture/captureFlow';
import { withAlpha } from '@/ui/color';
import { AppText, useTextStyle } from '@/ui/components/AppText';
import { Icon } from '@/ui/components/Icon';
import { LocationLine } from '@/ui/components/LocationLine';
import { rippleFor, usesRipple } from '@/ui/components/PressFeedback';
import { Tape } from '@/ui/components/Tape';
import { duration, easing, useReducedMotion } from '@/ui/motion';
import { MIN_TOUCH_TARGET, camera, radius, space, useTheme } from '@/ui/theme';

/*
 * The capture screen's chrome: everything drawn over the live picture.
 *
 * All of it is white on translucent dark chips (`camera` tokens), readable
 * over any scene in either colour scheme. None of it touches the camera: the
 * preview, the tap-to-focus layer and the shutter mechanics stay in
 * `app/capture/index.tsx`, untouched. Decorative pieces never
 * take touches, so a tap anywhere else still reaches the focus layer.
 */

/** White at 85 %: the reticle and the hint, quieter than the controls. */
const SOFT_INK = withAlpha(camera.ink, 0.85);

const SHUTTER = 76;
const SHUTTER_DISC = 62;
const SIDE_SLOT = MIN_TOUCH_TARGET;

/**
 * Corner guides: they show how much of the frame the item should fill, which
 * is what makes a photo recognisable. Framing guidance only; the photo is not
 * cropped to it.
 */
export function Reticle() {
  return (
    <View
      style={styles.reticle}
      pointerEvents="none"
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
    >
      <View style={[styles.corner, styles.cornerTopLeft]} />
      <View style={[styles.corner, styles.cornerTopRight]} />
      <View style={[styles.corner, styles.cornerBottomLeft]} />
      <View style={[styles.corner, styles.cornerBottomRight]} />
    </View>
  );
}

/**
 * A brief white flash each time a fast-mode shot comes back, so a shot that
 * landed is seen as well as felt. `trigger` is the newest photo's URI. Skipped
 * under reduced motion.
 */
export function ShutterFlash({ trigger }: { trigger: string | null }) {
  const reduced = useReducedMotion();
  const [opacity] = useState(() => new Animated.Value(0));

  useEffect(() => {
    if (!trigger || reduced) return;
    opacity.setValue(0);
    const half = duration.shutterFlash / 2;
    const flash = Animated.sequence([
      Animated.timing(opacity, { toValue: 0.5, duration: half, useNativeDriver: true }),
      Animated.timing(opacity, {
        toValue: 0,
        duration: half,
        easing: easing.out,
        useNativeDriver: true,
      }),
    ]);
    flash.start();
    return () => flash.stop();
  }, [opacity, reduced, trigger]);

  return (
    <Animated.View
      pointerEvents="none"
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={[StyleSheet.absoluteFill, { backgroundColor: camera.ink, opacity }]}
    />
  );
}

/**
 * Where the photos will go, at the top of the camera: "● Garage › Tool chest
 * [CAB-J92R]" or "Into the drop zone". Nothing until a container's details
 * have loaded, rather than a wrong guess.
 */
export function IntoPill({ containerId, place }: { containerId: string; place: PlaceLike | null }) {
  const dropZone = containerId === DROP_ZONE_CONTAINER_ID;
  if (!dropZone && !place) return null;

  return (
    <View
      pointerEvents="none"
      accessible
      accessibilityRole="text"
      accessibilityLabel={intoA11y(containerId, place)}
      style={[styles.pill, { backgroundColor: camera.chip }]}
    >
      {dropZone || !place ? (
        <>
          <Icon name="inbox" size={16} color={camera.ink} />
          <AppText variant="meta" tone="camera" numberOfLines={2} style={styles.shrink}>
            {strings.capture.into}
          </AppText>
        </>
      ) : (
        <LocationLine place={place} size="inline" tone="camera" />
      )}
    </View>
  );
}

export interface CameraNoticeProps {
  message: string;
  /** `assertive` for what stopped the camera, `polite` for what can wait. */
  live: 'assertive' | 'polite';
  action?: { label: string; onPress: () => void; testID?: string };
  testID?: string;
}

/**
 * A notice over the camera: a 4 pt coral bar, a warning icon and white text on
 * a dark chip. The text stays white because coral on a chip over a bright
 * scene is only 2.5:1.
 */
export function CameraNotice({ message, live, action, testID }: CameraNoticeProps) {
  // Android reads the live region; iOS needs the message announced.
  useEffect(() => {
    if (Platform.OS === 'ios') AccessibilityInfo.announceForAccessibility(message);
  }, [message]);

  return (
    <View
      testID={testID}
      accessibilityLiveRegion={live}
      style={[styles.notice, { backgroundColor: camera.chip }]}
    >
      <View style={[styles.noticeBar, { backgroundColor: camera.errorBar }]} />
      <View style={styles.noticeBody}>
        <View style={styles.noticeText}>
          <Icon name="warning" size={20} color={camera.ink} />
          <AppText variant="meta" tone="camera" style={styles.shrink}>
            {message}
          </AppText>
        </View>
        {action ? (
          <CameraTextButton label={action.label} onPress={action.onPress} testID={action.testID} />
        ) : null}
      </View>
    </View>
  );
}

/** A quiet white text button for the camera's notices ("Type it instead"). */
function CameraTextButton({
  label,
  onPress,
  testID,
}: {
  label: string;
  onPress: () => void;
  testID?: string;
}) {
  const { colors } = useTheme();
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={label}
      testID={testID}
      android_ripple={rippleFor(colors, { color: camera.chipPressed })}
      style={styles.textButton}
    >
      {({ pressed }) => (
        <>
          {pressed && !usesRipple ? (
            <View
              pointerEvents="none"
              style={[StyleSheet.absoluteFill, styles.textButtonPressed]}
            />
          ) : null}
          <Icon name="keyboard" size={20} color={camera.ink} />
          <AppText variant="label" tone="camera">
            {label}
          </AppText>
        </>
      )}
    </Pressable>
  );
}

export interface ShutterProps {
  onPress: () => void;
  /** Single mode while the photo is being saved: a spinner, and no second press. */
  busy?: boolean;
  /**
   * Fast mode while the camera is still taking the last shot: the press would
   * be ignored, so the ring fades and an ignored tap is visible.
   */
  dimmed?: boolean;
}

/** The shutter: a 3 pt white ring around a white disc, 76 pt across. */
export function Shutter({ onPress, busy = false, dimmed = false }: ShutterProps) {
  return (
    <Pressable
      onPress={onPress}
      disabled={busy}
      accessibilityRole="button"
      accessibilityLabel={strings.capture.takePhoto}
      accessibilityState={{ busy, disabled: busy }}
      testID="capture-shutter"
      style={[styles.shutter, { borderColor: camera.ink, opacity: dimmed ? 0.5 : 1 }]}
    >
      {({ pressed }) => (
        <View
          style={[
            styles.shutterDisc,
            { backgroundColor: camera.ink },
            pressed && !busy ? styles.shutterPressed : null,
          ]}
        >
          {busy ? <ActivityIndicator color={camera.bg} /> : null}
        </View>
      )}
    </Pressable>
  );
}

/**
 * The newest photo of a fast set as a small tile with the running count on
 * tape, so each shot visibly lands. Decorative: the status pill says the same
 * in words.
 */
export function LastShot({ uri, count }: { uri: string | null; count: number }) {
  if (!uri) return <View style={styles.sideSpacer} />;
  return (
    <View
      pointerEvents="none"
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={styles.lastShot}
    >
      <Image
        source={{ uri }}
        resizeMode="cover"
        accessibilityIgnoresInvertColors
        style={[styles.lastShotImage, { borderColor: camera.ink }]}
      />
      {count > 0 ? (
        <View style={styles.lastShotBadge}>
          <Tape code={String(count)} size="badge" />
        </View>
      ) : null}
    </View>
  );
}

/**
 * Ends a fast set: "Done · 4", the count in the camera accent. Dimmed until
 * the first shot, when it simply closes the camera.
 */
export function DoneButton({ count, onPress }: { count: number; onPress: () => void }) {
  const { colors } = useTheme();
  // Bold, so the accent count reads as large text over any scene (3.8:1 at worst).
  const countType = useTextStyle('name', 700);
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={strings.capture.doneA11y(count)}
      testID="capture-done"
      android_ripple={rippleFor(colors, { color: camera.chipPressed })}
      style={[styles.done, { backgroundColor: camera.chip, opacity: count > 0 ? 1 : 0.55 }]}
    >
      {({ pressed }) => (
        <>
          {pressed && !usesRipple ? (
            <View pointerEvents="none" style={[StyleSheet.absoluteFill, styles.donePressed]} />
          ) : null}
          <AppText variant="name" tone="camera" numberOfLines={1}>
            {strings.capture.done}
            {count > 0 ? (
              <Text style={[countType, styles.doneCount, { color: camera.accent }]}>
                {` · ${count}`}
              </Text>
            ) : null}
          </AppText>
        </>
      )}
    </Pressable>
  );
}

/** Keeps the shutter centred when one side has nothing to show. */
export function SideSpacer() {
  return <View style={styles.sideSpacer} />;
}

const styles = StyleSheet.create({
  reticle: {
    position: 'absolute',
    top: '22%',
    bottom: '28%',
    left: '10%',
    right: '10%',
  },
  corner: {
    position: 'absolute',
    width: 40,
    height: 40,
    borderColor: SOFT_INK,
  },
  cornerTopLeft: {
    top: 0,
    left: 0,
    borderTopWidth: 3,
    borderLeftWidth: 3,
    borderTopLeftRadius: radius.sheet,
  },
  cornerTopRight: {
    top: 0,
    right: 0,
    borderTopWidth: 3,
    borderRightWidth: 3,
    borderTopRightRadius: radius.sheet,
  },
  cornerBottomLeft: {
    bottom: 0,
    left: 0,
    borderBottomWidth: 3,
    borderLeftWidth: 3,
    borderBottomLeftRadius: radius.sheet,
  },
  cornerBottomRight: {
    bottom: 0,
    right: 0,
    borderBottomWidth: 3,
    borderRightWidth: 3,
    borderBottomRightRadius: radius.sheet,
  },
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.xs + 2,
    minHeight: 36,
    maxWidth: '100%',
    paddingHorizontal: space.md,
    paddingVertical: space.xs + 2,
    borderRadius: radius.pill,
  },
  shrink: {
    flexShrink: 1,
  },
  notice: {
    borderRadius: radius.card,
    borderCurve: 'continuous',
    overflow: 'hidden',
    flexDirection: 'row',
  },
  noticeBar: {
    width: 4,
  },
  noticeBody: {
    flex: 1,
    paddingVertical: space.md,
    paddingStart: space.md,
    paddingEnd: space.lg,
    gap: space.xs,
    alignItems: 'flex-start',
  },
  noticeText: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: space.sm,
  },
  textButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    minHeight: MIN_TOUCH_TARGET,
    paddingHorizontal: space.sm,
    marginStart: -space.sm,
    borderRadius: radius.control,
    overflow: 'hidden',
  },
  textButtonPressed: {
    backgroundColor: camera.chipPressed,
    borderRadius: radius.control,
  },
  shutter: {
    width: SHUTTER,
    height: SHUTTER,
    borderRadius: SHUTTER / 2,
    borderWidth: 3,
    alignItems: 'center',
    justifyContent: 'center',
  },
  shutterDisc: {
    width: SHUTTER_DISC,
    height: SHUTTER_DISC,
    borderRadius: SHUTTER_DISC / 2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  shutterPressed: {
    transform: [{ scale: 0.92 }],
  },
  sideSpacer: {
    width: SIDE_SLOT,
    height: SIDE_SLOT,
  },
  lastShot: {
    width: SIDE_SLOT,
    height: SIDE_SLOT,
  },
  lastShotImage: {
    width: SIDE_SLOT,
    height: SIDE_SLOT,
    borderRadius: radius.thumb,
    borderWidth: 2,
  },
  lastShotBadge: {
    position: 'absolute',
    top: -6,
    right: -6,
  },
  done: {
    minHeight: MIN_TOUCH_TARGET,
    minWidth: 96,
    paddingHorizontal: space.lg,
    borderRadius: MIN_TOUCH_TARGET / 2,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  donePressed: {
    backgroundColor: camera.chipPressed,
  },
  doneCount: {
    fontVariant: ['tabular-nums'],
  },
});
