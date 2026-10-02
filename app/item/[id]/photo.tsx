import { useState } from 'react';
import { ActivityIndicator, Image, StyleSheet, View } from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import { IconButton } from '@/ui/components/IconButton';
import { camera, fixed, space } from '@/ui/theme';

/**
 * The item's photo, full screen. A first version, so the route exists from the
 * start; S4 links to it from the item screen and builds the full viewer (spec
 * §5.13: pinch-zoom, swipe-down to close).
 */
export default function PhotoScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const repos = useRepositories();
  const insets = useSafeAreaInsets();
  const [failed, setFailed] = useState(false);
  const { data: item, loading } = useInventoryQuery(() => repos.items.getById(id), `item:${id}`);
  const uri = item?.photoUri ?? item?.photoThumbUri ?? null;

  return (
    <View style={[styles.viewer, { backgroundColor: fixed.photoBackdrop }]}>
      <StatusBar style="light" />
      {uri && !failed ? (
        <Image
          source={{ uri }}
          resizeMode="contain"
          onError={() => setFailed(true)}
          accessibilityIgnoresInvertColors
          accessibilityLabel={item?.name || strings.entities.unnamedItem}
          style={styles.photo}
        />
      ) : loading && item === null ? (
        <ActivityIndicator color={camera.ink} />
      ) : null}
      <View style={[styles.close, { top: insets.top + space.sm, start: insets.left + space.sm }]}>
        <IconButton
          icon="close"
          variant="camera"
          accessibilityLabel={strings.common.close}
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
    alignItems: 'center',
    justifyContent: 'center',
  },
  photo: {
    width: '100%',
    height: '100%',
  },
  close: {
    position: 'absolute',
  },
});
