import { useRef, useState, type ReactNode } from 'react';
import {
  ActivityIndicator,
  Animated,
  Image,
  Platform,
  ScrollView,
  StyleSheet,
  View,
  useWindowDimensions,
  type GestureResponderEvent,
} from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useDelayedFlag } from '@/hooks/useDelayedFlag';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import { AppText } from '@/ui/components/AppText';
import { IconButton } from '@/ui/components/IconButton';
import { describeError } from '@/ui/errors';
import { duration, easing, useReducedMotion } from '@/ui/motion';
import { GUTTER, camera, fixed, shadowFloat, space, useTheme } from '@/ui/theme';

/** A downward drag longer than this closes the viewer. */
const CLOSE_DRAG = 80;

/** A drag counts once it is clearly downward, not a wobble or a sideways pan. */
const DRAG_START = 10;

/** Plain words on the dark backdrop, for when there is no picture to show. */
function Message({ title, body, action }: { title: string; body?: string; action?: ReactNode }) {
  return (
    <View style={styles.message} accessibilityLiveRegion="polite">
      <AppText variant="heading" tone="camera" center>
        {title}
      </AppText>
      {body ? (
        <AppText variant="body" tone="camera" center>
          {body}
        </AppText>
      ) : null}
      {action}
    </View>
  );
}

/**
 * The item's photo, full screen, opened from the thumbnail on
 * the item screen now that the photo is no longer a 260 pt banner there.
 *
 * iOS zooms natively: the picture sits in a scroll view that pinches up to
 * 4×. Android's scroll view cannot zoom, and there is no gesture library in
 * the app, so it shows the whole picture fitted. Close with the button, a
 * downward swipe when not zoomed in, or Android back.
 */
export default function PhotoScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const repos = useRepositories();
  const insets = useSafeAreaInsets();
  const window = useWindowDimensions();
  const { isDark } = useTheme();
  const reduceMotion = useReducedMotion();
  const {
    data: item,
    loading,
    cause,
    reload,
  } = useInventoryQuery(() => repos.items.getById(id), `item:${id}`);
  const [failedUri, setFailedUri] = useState<string | null>(null);
  const showSpinner = useDelayedFlag(loading && item === null);

  // Read and written by the gesture handlers only, never while rendering.
  const zoomRef = useRef(1);
  const touchStartRef = useRef({ x: 0, y: 0 });
  const [drag] = useState(() => new Animated.Value(0));

  function dragged(event: GestureResponderEvent): { dx: number; dy: number } {
    return {
      dx: event.nativeEvent.pageX - touchStartRef.current.x,
      dy: event.nativeEvent.pageY - touchStartRef.current.y,
    };
  }

  /** Back to where it was after a drag too short to close. */
  function settle() {
    if (reduceMotion) {
      drag.setValue(0);
      return;
    }
    Animated.timing(drag, {
      toValue: 0,
      duration: duration.expand,
      easing: easing.settle,
      useNativeDriver: true,
    }).start();
  }

  const uri = item?.photoUri ?? item?.photoThumbUri ?? null;
  const frame = {
    width: window.width - insets.left - insets.right,
    height: window.height - insets.top - insets.bottom,
  };
  const label = item?.name ? strings.photo.a11y(item.name) : strings.photo.a11yUnnamed;

  let content: ReactNode = null;
  if (item === null) {
    if (cause) {
      const described = describeError(cause, 'read', 'item');
      content = (
        <Message
          title={described.title}
          body={described.body}
          action={
            <IconButton
              icon="refresh"
              variant="camera"
              accessibilityLabel={strings.common.tryAgain}
              onPress={reload}
            />
          }
        />
      );
    } else if (loading) {
      content = showSpinner ? <ActivityIndicator color={camera.ink} /> : null;
    } else {
      content = <Message title={strings.errors.gone.item} body={strings.errors.gone.body} />;
    }
  } else if (!uri || uri === failedUri) {
    content = <Message title={strings.errors.photo.title} body={strings.errors.photo.body} />;
  } else {
    const picture = (
      <Image
        source={{ uri }}
        resizeMode="contain"
        onError={() => setFailedUri(uri)}
        accessible
        accessibilityRole="image"
        accessibilityLabel={label}
        accessibilityIgnoresInvertColors
        style={frame}
      />
    );
    content =
      Platform.OS === 'ios' ? (
        <ScrollView
          style={frame}
          contentContainerStyle={frame}
          maximumZoomScale={4}
          minimumZoomScale={1}
          centerContent
          bounces={false}
          bouncesZoom
          showsHorizontalScrollIndicator={false}
          showsVerticalScrollIndicator={false}
          onScroll={(event) => {
            zoomRef.current = event.nativeEvent.zoomScale ?? 1;
          }}
          scrollEventThrottle={16}
        >
          {picture}
        </ScrollView>
      ) : (
        picture
      );
  }

  return (
    <View
      // Swipe down to close, with the responder props rather than a
      // PanResponder: only a one-finger downward drag at zoom 1 is taken; a
      // pinch, or a pan of a zoomed picture, belongs to the scroll view.
      onTouchStart={(event) => {
        touchStartRef.current = { x: event.nativeEvent.pageX, y: event.nativeEvent.pageY };
      }}
      onMoveShouldSetResponder={(event) => {
        const { dx, dy } = dragged(event);
        return (
          zoomRef.current <= 1.01 &&
          event.nativeEvent.touches.length === 1 &&
          dy > DRAG_START &&
          dy > Math.abs(dx) * 1.5
        );
      }}
      onResponderMove={(event) => drag.setValue(Math.max(0, dragged(event).dy))}
      onResponderRelease={(event) => {
        if (dragged(event).dy > CLOSE_DRAG) router.back();
        else settle();
      }}
      onResponderTerminationRequest={() => true}
      onResponderTerminate={settle}
      style={[
        styles.viewer,
        {
          backgroundColor: fixed.photoBackdrop,
          paddingTop: insets.top,
          paddingBottom: insets.bottom,
          paddingLeft: insets.left,
          paddingRight: insets.right,
        },
      ]}
    >
      <StatusBar style="light" />
      <Animated.View style={[styles.stage, { transform: [{ translateY: drag }] }]}>
        {content}
      </Animated.View>
      <View
        style={[
          styles.close,
          {
            top: insets.top + space.sm,
            start: insets.left + space.sm,
            boxShadow: isDark ? shadowFloat.dark : shadowFloat.light,
          },
        ]}
      >
        <IconButton
          icon="close"
          variant="camera"
          accessibilityLabel={strings.photo.close}
          onPress={() => router.back()}
          testID="photo-close"
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  viewer: {
    flex: 1,
  },
  stage: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  message: {
    alignItems: 'center',
    gap: space.sm,
    paddingHorizontal: GUTTER * 2,
    maxWidth: 480,
  },
  close: {
    position: 'absolute',
    borderRadius: 24,
  },
});
