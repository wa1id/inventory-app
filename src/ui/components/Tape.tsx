import { Platform, StyleSheet, View } from 'react-native';

import { strings } from '@/i18n/strings';
import { spellCode } from '@/ui/a11y';
import { AppText } from '@/ui/components/AppText';
import { fixed, radius, useTheme } from '@/ui/theme';
import type { TextVariant } from '@/ui/typography';

type TapeSize = 's' | 'm' | 'l' | 'badge';

export interface TapeProps {
  /** Rendered exactly as stored, as it is written on the box. */
  code: string;
  size?: TapeSize;
  /**
   * Make the tape its own focusable text, spelled out ("label D R W, 7 K 2 M").
   * Otherwise it is decorative and the parent's label carries the code.
   */
  spoken?: boolean;
  testID?: string;
}

const VARIANT: Record<TapeSize, TextVariant> = {
  s: 'tapeS',
  m: 'tapeM',
  l: 'tapeL',
  badge: 'badge',
};

// Inset shadows need Android 10; older phones get flat tape, which reads fine.
const embossed = !(Platform.OS === 'android' && Number(Platform.Version) < 29);

/**
 * Yellow label tape: the container code looking like the label on the box,
 * because that is what it is. The one loud thing in the design, so yellow is
 * never used on a button or a selection. It never wraps, truncates or
 * stretches; when space runs out the whole tape moves to the next line.
 */
export function Tape({ code, size = 's', spoken = false, testID }: TapeProps) {
  const { colors } = useTheme();

  return (
    <View
      testID={testID}
      accessible={spoken}
      accessibilityRole={spoken ? 'text' : undefined}
      accessibilityLabel={spoken ? strings.a11y.labelCode(spellCode(code)) : undefined}
      accessibilityElementsHidden={!spoken}
      importantForAccessibility={spoken ? 'yes' : 'no-hide-descendants'}
      style={[
        styles.tape,
        styles[size],
        embossed ? EMBOSS[size] : null,
        { backgroundColor: colors.tape },
      ]}
    >
      <AppText variant={VARIANT[size]} tone="tapeInk" numberOfLines={1} center>
        {code}
      </AppText>
    </View>
  );
}

const EMBOSS = StyleSheet.create({
  s: {
    boxShadow: fixed.tapeBevel,
  },
  m: {
    boxShadow: fixed.tapeBevel,
  },
  l: {
    boxShadow: fixed.tapeBevelL,
  },
  badge: {},
});

const styles = StyleSheet.create({
  tape: {
    flexShrink: 0,
    alignSelf: 'flex-start',
  },
  s: {
    paddingHorizontal: 6,
    paddingTop: 4,
    paddingBottom: 3,
    borderRadius: radius.tape,
  },
  m: {
    paddingHorizontal: 8,
    paddingTop: 5,
    paddingBottom: 4,
    borderRadius: radius.tape,
  },
  l: {
    paddingHorizontal: 12,
    paddingTop: 8,
    paddingBottom: 6,
    borderRadius: radius.tapeL,
  },
  badge: {
    paddingHorizontal: 6,
    paddingTop: 2,
    paddingBottom: 2,
    minWidth: 20,
    minHeight: 20,
    borderRadius: radius.pill,
    justifyContent: 'center',
  },
});
