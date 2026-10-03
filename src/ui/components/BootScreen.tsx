import { StyleSheet, View } from 'react-native';

import { useDelayedFlag } from '@/hooks/useDelayedFlag';
import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import { Mark } from '@/ui/components/Mark';
import { delay } from '@/ui/motion';
import { space, useTheme } from '@/ui/theme';

/**
 * What shows while the database opens, onboarding is read and the household
 * session comes back from secure storage. Usually that is a blink, so the
 * caption only appears if it takes longer than 400 ms.
 */
export function BootScreen() {
  const { colors } = useTheme();
  const showCaption = useDelayedFlag(true, delay.bootCaption);

  return (
    <View style={[styles.boot, { backgroundColor: colors.plaster }]}>
      <Mark size={52} />
      <View style={styles.caption} accessibilityLiveRegion="polite">
        {showCaption ? (
          <AppText variant="meta" tone="graphite" center>
            {strings.boot.opening}
          </AppText>
        ) : null}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  boot: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.lg,
    padding: space.xl,
  },
  // Reserves the caption's line so the mark does not move when it appears.
  caption: {
    minHeight: 20,
  },
});
