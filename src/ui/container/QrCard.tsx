import { StyleSheet, View, useWindowDimensions } from 'react-native';
import QRCode from 'react-native-qrcode-svg';

import { strings } from '@/i18n/strings';
import { formatQrPayload } from '@/repositories/qr';
import { spellCode } from '@/ui/a11y';
import { AppText } from '@/ui/components/AppText';
import { Tape } from '@/ui/components/Tape';
import { labelOf } from '@/ui/container/containerRules';
import type { QrSvg } from '@/ui/container/labelImage';
import { GUTTER, fixed, radius, space, useTheme } from '@/ui/theme';

/** The code's modules on screen (spec §5.8). */
const MODULES = 220;
/**
 * White drawn into the picture itself around the modules, so a saved or
 * printed copy still has the quiet zone scanners need, whatever it is
 * printed on. The card's padding adds more on screen.
 */
const QUIET = 16;
const PADDING = space.xl;

export interface QrCardProps {
  token: string;
  container: { name: string | null; shortCode: string };
  /** Receives the drawing, to share it as a picture. */
  onSvg?: (svg: QrSvg | null) => void;
}

/**
 * The label as it will be printed: the QR code over the container's name and
 * its code on tape.
 *
 * Always black on white, in dark mode too, because scanners need the contrast
 * and a sticker is printed on white (entities §14.14). The payload is the
 * unchanged `inventory://c/<token>` link, so the phone's own camera opens the
 * container as well. On a narrow phone the code shrinks to fit rather than
 * overflowing the card.
 */
export function QrCard({ token, container, onSvg }: QrCardProps) {
  const { colors, isDark } = useTheme();
  const { width } = useWindowDimensions();
  const room = width - 2 * GUTTER - 2 * PADDING - 2;
  const modules = Math.max(120, Math.min(MODULES, room - 2 * QUIET));
  const size = modules + 2 * QUIET;
  // The library sizes the quiet zone in the code's own units: this many of
  // them make `QUIET` points once the drawing is scaled to `size`.
  const quietZone = (size * size) / modules / 2 - size / 2;
  const named = container.name?.trim() ? container.name : null;

  return (
    <View
      accessible
      accessibilityRole="image"
      accessibilityLabel={strings.qr.cardA11y(labelOf(container), spellCode(container.shortCode))}
      testID="qr-card"
      style={[
        styles.card,
        { backgroundColor: fixed.qrPaper },
        // In dark mode the white card keeps the dark rule, so its edge sits
        // with the other sheets instead of glowing.
        isDark ? { borderWidth: 1, borderColor: colors.rule } : null,
      ]}
    >
      <QRCode
        value={formatQrPayload(token)}
        size={size}
        quietZone={quietZone}
        color={fixed.qrInk}
        backgroundColor={fixed.qrPaper}
        getRef={onSvg}
      />
      {named ? (
        <AppText variant="heading" center style={styles.name}>
          {named}
        </AppText>
      ) : null}
      {/* Its own box: the tape holds itself to the start, and the card centres. */}
      <View>
        <Tape code={container.shortCode} size="l" />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    alignSelf: 'center',
    alignItems: 'center',
    gap: space.md,
    padding: PADDING,
    borderRadius: radius.sheet,
    borderCurve: 'continuous',
  },
  name: {
    color: fixed.qrInk,
  },
});
