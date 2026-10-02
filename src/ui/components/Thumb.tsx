import { useState } from 'react';
import { Image, Platform, Pressable, StyleSheet, View } from 'react-native';

import { Icon } from '@/ui/components/Icon';
import { PressedOverlay, rippleFor, useFocusRing } from '@/ui/components/PressFeedback';
import { MIN_TOUCH_TARGET, radius, useTheme } from '@/ui/theme';

export interface ThumbProps {
  /** Callers pass `photoThumbUri ?? photoUri`: lists never load a full photo (`4fa33a6`). */
  uri?: string | null;
  /** 40 for small marks inside other controls (a field, a card's stack). */
  size: 40 | 48 | 56 | 76 | 88;
  /** Item screen only: opens the photo full screen. */
  onPress?: () => void;
  accessibilityLabel?: string;
  testID?: string;
}

/**
 * An item's photo, or the same `photo` placeholder whatever the container
 * type (the old 🧾/📦 mix said nothing). A photo that fails to load (a
 * missing file, a household photo that is not cached) leaves the placeholder.
 */
export function Thumb({ uri, size, onPress, accessibilityLabel, testID }: ThumbProps) {
  const { colors } = useTheme();
  const focus = useFocusRing();
  // Remembers which uri failed, so a recycled row with a new photo tries again.
  const [failedUri, setFailedUri] = useState<string | null>(null);
  const showImage = uri ? uri !== failedUri : false;

  const picture = (
    <>
      <Icon name="photo" size={size > 56 ? 24 : 20} color={colors.graphite} />
      {showImage && uri ? (
        <Image
          source={{ uri }}
          resizeMode="cover"
          fadeDuration={Platform.OS === 'android' ? 0 : undefined}
          onError={() => setFailedUri(uri)}
          accessibilityIgnoresInvertColors
          style={StyleSheet.absoluteFill}
        />
      ) : null}
    </>
  );

  const frame = [styles.thumb, { width: size, height: size, backgroundColor: colors.sheet2 }];

  if (!onPress) {
    return (
      <View
        testID={testID}
        style={frame}
        accessibilityElementsHidden
        importantForAccessibility="no-hide-descendants"
      >
        {picture}
      </View>
    );
  }

  return (
    <Pressable
      testID={testID}
      onPress={onPress}
      // A 40 pt thumb still takes a full-size press.
      hitSlop={Math.max(0, (MIN_TOUCH_TARGET - size) / 2)}
      onFocus={focus.onFocus}
      onBlur={focus.onBlur}
      accessibilityRole="imagebutton"
      accessibilityLabel={accessibilityLabel}
      android_ripple={rippleFor(colors)}
      style={[frame, focus.ringStyle]}
    >
      {({ pressed }) => (
        <>
          {picture}
          <PressedOverlay pressed={pressed} />
        </>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  thumb: {
    borderRadius: radius.thumb,
    overflow: 'hidden',
    alignItems: 'center',
    justifyContent: 'center',
    flexShrink: 0,
  },
});
