import { ActivityIndicator, Linking, StyleSheet, View } from 'react-native';
import type { PermissionResponse } from 'expo-camera';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useDelayedFlag } from '@/hooks/useDelayedFlag';
import { strings } from '@/i18n/strings';
import { useHousehold } from '@/providers/HouseholdProvider';
import { logEvent } from '@/services/telemetry';
import { AppText } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { Icon } from '@/ui/components/Icon';
import { IconButton } from '@/ui/components/IconButton';
import { delay } from '@/ui/motion';
import { CONTENT_MAX_WIDTH, GUTTER, camera, space, useTheme } from '@/ui/theme';

/** Room above the content for the close button. */
const MIN_TOP = 72;

export interface CameraPermissionProps {
  purpose: 'capture' | 'scan';
  /**
   * The screen's own `useCameraPermissions()` result. The screen owns the hook
   * so that, once granted, it is the screen that switches to the camera: a
   * second hook here would not see the answer.
   */
  permission: PermissionResponse | null;
  requestPermission: () => Promise<PermissionResponse>;
  /** Type the item (capture) or the label code (scan) instead. */
  onManual?: () => void;
  /** Capture only: pick a photo from the library instead. */
  onLibrary?: () => void;
  /** Closes the camera screen; the Scan tab has nothing to close. */
  onCancel?: () => void;
  /** The close button's testID, so each camera screen keeps its own. */
  closeTestID?: string;
}

/**
 * The one camera-permission screen, for capturing and for scanning.
 *
 * While the permission is still being read it stays black for a moment, then
 * shows a spinner, never a blank screen. Before the system prompt it says what
 * the camera is for (and, for photos, where they go); after a permanent "no"
 * it points to Settings. A way to carry on without the camera is always one
 * tap away. Both purposes log `permission_result`.
 */
export function CameraPermission({
  purpose,
  permission,
  requestPermission,
  onManual,
  onLibrary,
  onCancel,
  closeTestID = 'camera-close',
}: CameraPermissionProps) {
  const { colors } = useTheme();
  const insets = useSafeAreaInsets();
  const { session } = useHousehold();
  const showSpinner = useDelayedFlag(permission === null, delay.skeleton);

  const close = onCancel ? (
    <View style={[styles.close, { top: insets.top + space.sm, start: insets.left + space.sm }]}>
      <IconButton
        icon="close"
        variant="camera"
        accessibilityLabel={strings.camera.close}
        onPress={onCancel}
        testID={closeTestID}
      />
    </View>
  ) : null;

  if (!permission) {
    return (
      <View style={[styles.fill, styles.centered, { backgroundColor: camera.bg }]}>
        {showSpinner ? <ActivityIndicator color={camera.ink} /> : null}
        {close}
      </View>
    );
  }

  const blocked = !permission.canAskAgain;
  const scan = purpose === 'scan';
  const body = blocked
    ? scan
      ? strings.permissions.offBodyScan
      : strings.permissions.offBodyCapture
    : scan
      ? strings.permissions.scanBody
      : session
        ? strings.permissions.captureBodyPaired
        : strings.permissions.captureBodyLocal;

  async function allow() {
    const next = await requestPermission();
    logEvent('permission_result', {
      permission: 'camera',
      outcome: next.granted ? 'granted' : 'denied',
    });
  }

  return (
    <View
      style={[
        styles.fill,
        {
          backgroundColor: colors.plaster,
          paddingTop: insets.top + MIN_TOP,
          paddingBottom: insets.bottom + space.xl,
        },
      ]}
    >
      <View style={styles.content}>
        <View style={[styles.iconCircle, { backgroundColor: colors.sheet2 }]}>
          <Icon name="camera" size={28} color={colors.graphite} />
        </View>
        <AppText variant="heading">
          {blocked
            ? strings.permissions.cameraDeniedTitle
            : strings.permissions.cameraRationaleTitle}
        </AppText>
        <AppText variant="body" tone="graphite">
          {body}
        </AppText>
        <View style={styles.actions}>
          {blocked ? (
            <Button
              label={strings.permissions.openSettings}
              onPress={() => void Linking.openSettings()}
              testID="camera-open-settings"
            />
          ) : (
            <Button
              label={strings.permissions.grant}
              onPress={() => void allow()}
              testID="camera-allow"
            />
          )}
          {scan && onManual ? (
            <Button
              label={strings.permissions.typeCodeInstead}
              icon="keyboard"
              variant="secondary"
              onPress={onManual}
              testID="camera-manual"
            />
          ) : null}
          {!scan && onLibrary ? (
            <Button
              label={strings.permissions.choosePhotoInstead}
              icon="gallery"
              variant="secondary"
              onPress={onLibrary}
              testID="camera-library"
            />
          ) : null}
          {!scan && onManual ? (
            <Button
              label={strings.permissions.typeItInstead}
              icon="keyboard"
              variant="quiet"
              onPress={onManual}
              testID="camera-manual"
            />
          ) : null}
        </View>
      </View>
      {close}
    </View>
  );
}

const styles = StyleSheet.create({
  fill: {
    flex: 1,
  },
  centered: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  content: {
    width: '100%',
    maxWidth: CONTENT_MAX_WIDTH,
    alignSelf: 'center',
    paddingHorizontal: GUTTER,
    gap: space.sm,
    alignItems: 'flex-start',
  },
  iconCircle: {
    width: 56,
    height: 56,
    borderRadius: 28,
    alignItems: 'center',
    justifyContent: 'center',
  },
  actions: {
    marginTop: space.md,
    gap: space.sm,
    alignItems: 'flex-start',
  },
  close: {
    position: 'absolute',
  },
});
