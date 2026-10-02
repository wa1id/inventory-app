import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Animated, PanResponder, Platform, Pressable, StyleSheet, View } from 'react-native';
import { FullWindowOverlay } from 'react-native-screens';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useLayoutScale } from '@/hooks/useLayoutScale';
import { strings } from '@/i18n/strings';
import { useToastHostState, type ToastRecord } from '@/providers/ToastProvider';
import { AppText } from '@/ui/components/AppText';
import { RevokedLayer } from '@/ui/components/ConnectionBanner';
import { Icon } from '@/ui/components/Icon';
import { IconButton } from '@/ui/components/IconButton';
import { duration, easing, motionMs, useReducedMotion } from '@/ui/motion';
import { GUTTER, MIN_TOUCH_TARGET, radius, space, useTheme } from '@/ui/theme';

/** Gap between the toast and the bottom chrome (or the home indicator). */
const TOAST_GAP = 12;
/** A downward drag this long dismisses the toast. */
const SWIPE_DISMISS = 24;

/**
 * Draws the current toast at the bottom of the window, above the focused
 * screen's tab bar or bottom bar. Touches outside the toast pass through.
 */
export function ToastHost() {
  const { current, leaving, chromeHeight, pause, resume, dismiss } = useToastHostState();
  const insets = useSafeAreaInsets();
  const bottom = (chromeHeight ?? insets.bottom) + TOAST_GAP;

  return (
    <View pointerEvents="box-none" style={StyleSheet.absoluteFill}>
      {current ? (
        <View pointerEvents="box-none" style={[styles.slot, { bottom }]}>
          <ToastCard
            key={current.id}
            toast={current}
            leaving={leaving}
            onPause={pause}
            onResume={resume}
            onDismiss={dismiss}
          />
        </View>
      ) : null}
    </View>
  );
}

interface ToastCardProps {
  toast: ToastRecord;
  leaving: boolean;
  onPause: () => void;
  onResume: () => void;
  /** Stable, and takes the id, so the swipe handler is made once per toast. */
  onDismiss: (id: string) => void;
}

function ToastCard({ toast, leaving, onPause, onResume, onDismiss }: ToastCardProps) {
  const { colors } = useTheme();
  const { stacked } = useLayoutScale();
  const reduced = useReducedMotion();
  // Keyed by the toast, so this is per toast: its action runs once, even if
  // tapped again while the toast fades (it stays pressable for that time).
  const actedRef = useRef(false);
  const [opacity] = useState(() => new Animated.Value(0));
  const [rise] = useState(() => new Animated.Value(reduced ? 0 : 8));
  const [drag] = useState(() => new Animated.Value(0));
  const error = toast.tone === 'error';

  useEffect(() => {
    const ms = motionMs(duration.toastIn, reduced);
    Animated.parallel([
      Animated.timing(opacity, {
        toValue: 1,
        duration: ms,
        easing: easing.out,
        useNativeDriver: true,
      }),
      Animated.timing(rise, {
        toValue: 0,
        duration: ms,
        easing: easing.out,
        useNativeDriver: true,
      }),
    ]).start();
  }, [opacity, reduced, rise]);

  useEffect(() => {
    if (!leaving) return;
    Animated.timing(opacity, {
      toValue: 0,
      duration: motionMs(duration.toastOut, reduced),
      easing: easing.exit,
      useNativeDriver: true,
    }).start();
  }, [leaving, opacity, reduced]);

  const pan = useMemo(() => {
    const settle = () => {
      if (reduced) drag.setValue(0);
      else Animated.spring(drag, { toValue: 0, useNativeDriver: true }).start();
    };
    return PanResponder.create({
      onMoveShouldSetPanResponder: (_, gesture) =>
        gesture.dy > 6 && Math.abs(gesture.dy) > Math.abs(gesture.dx),
      onPanResponderMove: (_, gesture) => drag.setValue(Math.max(0, gesture.dy)),
      onPanResponderRelease: (_, gesture) => {
        if (gesture.dy > SWIPE_DISMISS) onDismiss(toast.id);
        else settle();
      },
      onPanResponderTerminate: settle,
    });
  }, [drag, onDismiss, reduced, toast.id]);

  const icon = error ? (
    <View style={styles.icon}>
      <Icon name="warning" size={16} color={colors.toastInk} />
    </View>
  ) : null;
  // Never clipped: the instruction at the end of an error, or where a moved
  // item went, is the point of the toast.
  const message = (
    <AppText variant="meta" weight={600} tone="toastInk" style={styles.message}>
      {toast.message}
    </AppText>
  );
  const controls = (
    <>
      {toast.action ? (
        <ToastActionButton
          label={toast.action.label}
          accessibilityLabel={toast.action.accessibilityLabel}
          color={colors.toastAction}
          disabled={leaving}
          onPress={() => {
            if (actedRef.current) return;
            actedRef.current = true;
            toast.action?.onPress();
            onDismiss(toast.id);
          }}
        />
      ) : null}
      <IconButton
        icon="close"
        iconSize={20}
        iconColor={colors.toastInk}
        accessibilityLabel={strings.a11y.dismissToast}
        onPress={() => onDismiss(toast.id)}
        testID="toast-dismiss"
      />
    </>
  );

  return (
    <Animated.View
      {...pan.panHandlers}
      testID="toast"
      accessibilityRole={error ? 'alert' : undefined}
      accessibilityLiveRegion={error ? 'assertive' : 'polite'}
      onTouchStart={onPause}
      onTouchEnd={onResume}
      onTouchCancel={onResume}
      style={[
        styles.toast,
        stacked ? styles.toastStacked : null,
        {
          backgroundColor: colors.toastBg,
          boxShadow: colors.shadowFloat,
          opacity,
          transform: [{ translateY: Animated.add(rise, drag) }],
        },
      ]}
    >
      {error ? <View style={[styles.signalBar, { backgroundColor: colors.toastSignal }]} /> : null}
      {stacked ? (
        // Large text: the message keeps the full width, the buttons go under it.
        <>
          <View style={styles.messageRow}>
            {icon}
            {message}
          </View>
          <View style={styles.controlsRow}>{controls}</View>
        </>
      ) : (
        <>
          {icon}
          {message}
          {controls}
        </>
      )}
    </Animated.View>
  );
}

function ToastActionButton({
  label,
  accessibilityLabel,
  color,
  disabled = false,
  onPress,
}: {
  label: string;
  accessibilityLabel?: string;
  color: string;
  /** While the toast fades: not offered to screen readers any more. */
  disabled?: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityState={{ disabled }}
      hitSlop={4}
      testID="toast-action"
      style={({ pressed }) => [styles.action, { opacity: pressed ? 0.7 : 1 }]}
    >
      <AppText variant="label" weight={700} style={{ color }}>
        {label}
      </AppText>
    </Pressable>
  );
}

/**
 * Everything that floats above the navigation: the toast and the
 * removed-phone layer. On iOS they render in a `FullWindowOverlay`, a window
 * of their own above native modal sheets, so "Moved to …" with Undo is seen
 * while the move sheet slides away. On Android, sheets are ordinary screens,
 * so a view after the stack is already on top.
 */
export function OverlayHost() {
  const content: ReactNode = (
    <View pointerEvents="box-none" style={StyleSheet.absoluteFill}>
      <ToastHost />
      <RevokedLayer />
    </View>
  );

  return Platform.OS === 'ios' ? <FullWindowOverlay>{content}</FullWindowOverlay> : content;
}

const styles = StyleSheet.create({
  slot: {
    position: 'absolute',
    left: GUTTER,
    right: GUTTER,
    alignItems: 'center',
  },
  toast: {
    width: '100%',
    maxWidth: 480,
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    minHeight: MIN_TOUCH_TARGET + space.md,
    paddingTop: space.md,
    paddingBottom: space.sm,
    paddingStart: space.lg,
    paddingEnd: space.xs,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  toastStacked: {
    flexDirection: 'column',
    alignItems: 'stretch',
  },
  messageRow: {
    flexDirection: 'row',
    gap: space.sm,
    paddingEnd: space.md,
  },
  controlsRow: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    alignItems: 'center',
    gap: space.sm,
  },
  // Rounded on its own rather than clipped by the toast: clipping would also
  // cut off the toast's shadow.
  signalBar: {
    position: 'absolute',
    start: 0,
    top: 0,
    bottom: 0,
    width: 4,
    borderTopStartRadius: radius.card,
    borderBottomStartRadius: radius.card,
  },
  icon: {
    alignSelf: 'flex-start',
    paddingTop: 2,
  },
  message: {
    flex: 1,
    paddingBottom: space.xs,
  },
  action: {
    minHeight: MIN_TOUCH_TARGET,
    minWidth: MIN_TOUCH_TARGET,
    paddingHorizontal: space.sm,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
