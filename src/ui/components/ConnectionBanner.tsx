import { useEffect } from 'react';
import { AccessibilityInfo, BackHandler, Platform, StyleSheet, View } from 'react-native';
import { router } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { strings } from '@/i18n/strings';
import { useConnection } from '@/providers/ConnectionProvider';
import { useDatabase } from '@/providers/DatabaseProvider';
import { useHousehold } from '@/providers/HouseholdProvider';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { Button } from '@/ui/components/Button';
import { Mark } from '@/ui/components/Mark';
import { CONTENT_MAX_WIDTH, GUTTER, space, useTheme } from '@/ui/theme';

/**
 * "Reconnecting to the home server…", shown at the top of every screen once
 * requests have failed for 2.5 s, and gone as soon as one succeeds. Nothing
 * for brief blips, and nothing when the phone is not part of a household.
 * What was on screen stays; the banner only says it may be a few minutes old.
 *
 * Silent: every screen draws its own copy, so `ConnectionProvider` announces
 * the change once instead of each banner announcing itself as it mounts.
 */
export function ConnectionBanner() {
  const { state, retry } = useConnection();
  if (state !== 'offline') return null;

  return (
    <View style={styles.banner}>
      <Banner
        tone="warning"
        icon="cloudOff"
        message={strings.connection.reconnecting}
        action={{ label: strings.connection.retry, onPress: retry }}
        live="off"
        testID="banner-connection"
      />
    </View>
  );
}

/**
 * The one thing a removed phone sees, over every screen and sheet, instead of
 * an error on each of them: this phone is no longer part of the household,
 * and how to carry on. Leaves by itself once the phone has left the household
 * (either button), because the connection state stops being `revoked`.
 */
export function RevokedLayer() {
  const { state } = useConnection();
  if (state !== 'revoked') return null;
  return <RevokedContent />;
}

function RevokedContent() {
  const { colors } = useTheme();
  const insets = useSafeAreaInsets();
  const { disconnect } = useHousehold();
  const { invalidate } = useDatabase();

  useEffect(() => {
    // Close whatever was open underneath, so leaving the layer lands on Home.
    if (router.canDismiss()) router.dismissAll();
    if (Platform.OS === 'ios') AccessibilityInfo.announceForAccessibility(strings.revoked.title);
    // Android back must not reach the screens underneath.
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => true);
    return () => subscription.remove();
  }, []);

  // Leaving swaps the household's lists for this phone's own; nothing else
  // re-reads them, because the layer is not a screen and Home stays focused.
  async function joinAgain() {
    await disconnect();
    invalidate();
    router.push('/household');
  }

  async function carryOnAlone() {
    await disconnect();
    invalidate();
  }

  return (
    <View
      accessibilityViewIsModal
      style={[
        StyleSheet.absoluteFill,
        styles.layer,
        {
          backgroundColor: colors.plaster,
          paddingTop: insets.top + space.xxxl,
          paddingBottom: insets.bottom + space.xl,
        },
      ]}
    >
      <View style={styles.content}>
        <Mark />
        <AppText variant="heading">{strings.revoked.title}</AppText>
        <AppText variant="body" tone="graphite">
          {strings.revoked.body}
        </AppText>
        <View style={styles.actions}>
          <Button
            label={strings.revoked.join}
            onPress={() => void joinAgain()}
            fullWidth
            testID="revoked-join"
          />
          <Button
            label={strings.revoked.local}
            onPress={() => void carryOnAlone()}
            variant="quiet"
            fullWidth
            testID="revoked-local"
          />
        </View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  banner: {
    paddingHorizontal: GUTTER,
    paddingTop: space.sm,
    paddingBottom: space.xs,
  },
  layer: {
    paddingHorizontal: GUTTER,
  },
  content: {
    width: '100%',
    maxWidth: CONTENT_MAX_WIDTH,
    alignSelf: 'center',
    gap: space.md,
  },
  actions: {
    marginTop: space.lg,
    gap: space.sm,
  },
});
