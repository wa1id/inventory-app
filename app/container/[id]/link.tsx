import { StyleSheet, View } from 'react-native';
import { router } from 'expo-router';

import { strings } from '@/i18n/strings';
import { Button } from '@/ui/components/Button';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { space } from '@/ui/theme';

/**
 * Placeholder for linking a printed sticker to this container, so the route
 * and its full-screen presentation exist from the start. Nothing links here
 * yet; S3 replaces it with the scanner and its confirmations (spec §5.19).
 */
export default function LinkStickerScreen() {
  return (
    <ScreenFrame kind="tabRoot" banner={false}>
      <View style={styles.body}>
        <Button
          label={strings.common.goBack}
          icon="back"
          variant="secondary"
          onPress={() => router.back()}
          testID="link-back"
        />
      </View>
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  body: {
    padding: space.lg,
  },
});
