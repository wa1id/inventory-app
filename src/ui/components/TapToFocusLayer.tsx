import { useEffect, useState } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

import { strings } from '@/i18n/strings';

export const FOCUS_SPOT_SIZE = 72;
const FOCUS_SPOT_MS = 700;

export function focusSpotOffset(x: number, y: number): { left: number; top: number } {
  return { left: x - FOCUS_SPOT_SIZE / 2, top: y - FOCUS_SPOT_SIZE / 2 };
}

/**
 * Invisible tap target over the live preview (issue #44).
 *
 * Native tap-to-focus on the camera view only fires when nothing is sitting
 * on top of it. The capture chrome has to stay tappable, so this layer takes
 * preview taps, asks the camera to meter there, and draws the same kind of
 * fleeting square the system camera uses so the press feels like it did
 * something.
 */
export function TapToFocusLayer({
  onFocus,
}: {
  onFocus: (point: { x: number; y: number }) => void;
}) {
  const [spot, setSpot] = useState<{ x: number; y: number } | null>(null);

  useEffect(() => {
    if (!spot) return;
    const clear = setTimeout(() => setSpot(null), FOCUS_SPOT_MS);
    return () => clearTimeout(clear);
  }, [spot]);

  return (
    <Pressable
      style={StyleSheet.absoluteFill}
      onPress={(event) => {
        const { locationX, locationY } = event.nativeEvent;
        onFocus({ x: locationX, y: locationY });
        setSpot({ x: locationX, y: locationY });
      }}
      accessibilityRole="button"
      accessibilityLabel={strings.capture.tapToFocus}
      testID="capture-tap-focus"
    >
      {spot ? (
        <View
          pointerEvents="none"
          testID="capture-focus-spot"
          style={[styles.spot, focusSpotOffset(spot.x, spot.y)]}
        />
      ) : null}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  spot: {
    position: 'absolute',
    width: FOCUS_SPOT_SIZE,
    height: FOCUS_SPOT_SIZE,
    borderWidth: 2,
    borderColor: '#FFE566',
    borderRadius: 4,
    backgroundColor: 'transparent',
  },
});
