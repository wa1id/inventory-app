import type { ReactNode } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { strings } from '@/i18n/strings';
import { useHousehold } from '@/providers/HouseholdProvider';
import { MAX_IMAGE_DIMENSION } from '@/services/capture/imageScaling';
import { appConfig } from '@/services/config';
import { AppText } from '@/ui/components/AppText';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { GUTTER, space } from '@/ui/theme';

function Part({ title, children }: { title: string; children: ReactNode }) {
  return (
    <View style={styles.part}>
      <AppText variant="heading">{title}</AppText>
      {children}
    </View>
  );
}

function Body({ children }: { children: string }) {
  return (
    <AppText variant="body" tone="graphite">
      {children}
    </AppText>
  );
}

/**
 * In-app privacy notice covering camera and gallery data handling and
 * retention, required before beta (issue #8). What it says follows this
 * build (`appConfig`: backup service, photo suggestions) and this phone
 * (joined to a household or not), so it never promises something untrue:
 * a joined phone's inventory and photos live on the home server, and changes
 * need the internet. The paired copy awaits the owner's sign-off (spec Q7).
 */
export default function PrivacyScreen() {
  const insets = useSafeAreaInsets();
  const paired = useHousehold().session !== null;
  const copy = strings.privacy;

  return (
    <ScreenFrame kind="detail">
      <ScrollView
        contentContainerStyle={[styles.content, { paddingBottom: insets.bottom + space.xl }]}
      >
        {paired ? (
          <Part title={copy.householdTitle}>
            <Body>{copy.householdBody}</Body>
          </Part>
        ) : null}

        <Part title={copy.whereTitle}>
          <Body>{paired ? copy.whereBodyPaired : copy.whereBody}</Body>
          {appConfig.syncEndpoint ? (
            // "Nothing is uploaded" is not true of a joined phone.
            <Body>{paired ? copy.backupOffPaired : copy.backupOff}</Body>
          ) : (
            <Body>{paired ? copy.noBackupServicePaired : copy.noBackupService}</Body>
          )}
        </Part>

        {appConfig.syncEndpoint ? (
          <Part title={copy.backupTitle}>
            <Body>{copy.backupAccount}</Body>
            <Body>{copy.backupPassword}</Body>
            <Body>{copy.backupLocal}</Body>
          </Part>
        ) : null}

        <Part title={copy.cameraTitle}>
          <Body>{copy.cameraUse}</Body>
          <Body>{paired ? copy.photosPaired : copy.photosLocal}</Body>
          <Body>{copy.photosResized(MAX_IMAGE_DIMENSION)}</Body>
          <Body>{copy.photosDeleted}</Body>
        </Part>

        <Part title={copy.suggestionsTitle}>
          {appConfig.recognitionEndpoint ? (
            <>
              <Body>{copy.suggestionsSent}</Body>
              <Body>{copy.suggestionsPrivate}</Body>
            </>
          ) : (
            <Body>{copy.suggestionsOff}</Body>
          )}
        </Part>

        <Part title={copy.diagnosticsTitle}>
          <Body>{copy.diagnosticsBody}</Body>
        </Part>

        <Part title={copy.offlineTitle}>
          <Body>{paired ? copy.offlinePaired : copy.offlineBody}</Body>
        </Part>
      </ScrollView>
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  content: {
    padding: GUTTER,
    gap: space.xxl,
  },
  part: {
    gap: space.sm,
  },
});
