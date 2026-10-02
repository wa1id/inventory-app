import { StyleSheet, View } from 'react-native';

import { AppText } from '@/ui/components/AppText';
import { Icon, type IconName } from '@/ui/components/Icon';
import { camera, radius, space } from '@/ui/theme';

export interface StatusPillProps {
  icon?: IconName;
  text: string;
  /** Announce changes (a running count); off for a fixed title. */
  live?: boolean;
  testID?: string;
}

/** A dark pill of white text over the camera picture, readable on any scene. */
export function StatusPill({ icon, text, live = false, testID }: StatusPillProps) {
  return (
    <View
      testID={testID}
      accessibilityLiveRegion={live ? 'polite' : 'none'}
      style={[styles.pill, { backgroundColor: camera.chip }]}
    >
      {icon ? <Icon name={icon} size={16} color={camera.ink} /> : null}
      <AppText variant="meta" tone="camera" numberOfLines={2} style={styles.text}>
        {text}
      </AppText>
    </View>
  );
}

const styles = StyleSheet.create({
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.xs + 2,
    minHeight: 36,
    paddingHorizontal: space.md,
    paddingVertical: space.xs + 2,
    borderRadius: radius.pill,
    alignSelf: 'center',
    maxWidth: '100%',
  },
  text: {
    flexShrink: 1,
  },
});
