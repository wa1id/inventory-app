import { StyleSheet, View } from 'react-native';

import type { ItemWithContext } from '@/db/types';
import { useLayoutScale } from '@/hooks/useLayoutScale';
import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { Sheet } from '@/ui/components/Sheet';
import { Thumb } from '@/ui/components/Thumb';
import { radius, space, useTheme } from '@/ui/theme';

/** How many of the waiting items show a thumbnail on the card. */
const THUMBS = 3;
/** The 2 pt ring that separates one thumbnail from the one it overlaps. */
const RING = 2;

export interface DropZoneCardProps {
  /** The waiting items, newest first (`useDropZone`). */
  items: readonly ItemWithContext[];
  count: number;
  onSort: () => void;
  onQuickSnap: () => void;
}

/**
 * Home's reminder that some items are waiting for a place.
 *
 * Kept short so Recently added still starts on her first screen: the text
 * beside a small overlapping stack of the waiting photos, then the buttons.
 * At large text sizes and on the narrowest phones the stack goes above the
 * text, so the text is never squeezed into a narrow column.
 *
 * The card itself is not pressable: its two buttons sit side by side, so
 * Quick Snap is never a button inside a button (the old card at
 * `app/(tabs)/index.tsx:112-142` hid it from VoiceOver). Shown only while
 * something is waiting, so a first run is not led by an empty inbox.
 */
export function DropZoneCard({ items, count, onSort, onQuickSnap }: DropZoneCardProps) {
  const { colors } = useTheme();
  const { stacked } = useLayoutScale();
  return (
    <Sheet inset testID="drop-zone-card">
      <View style={stacked ? styles.headStacked : styles.head}>
        <View style={stacked ? styles.text : [styles.text, styles.textBeside]}>
          <AppText variant="section" accessibilityRole="header">
            {strings.home.dropZone.title(count)}
          </AppText>
          <AppText variant="meta" tone="graphite">
            {strings.home.dropZone.body}
          </AppText>
        </View>
        <View style={styles.thumbs}>
          {items.slice(0, THUMBS).map((item, index) => (
            <View
              key={item.id}
              style={[
                styles.ring,
                { borderColor: colors.sheet },
                index > 0 ? styles.overlap : null,
              ]}
            >
              <Thumb uri={item.photoThumbUri ?? item.photoUri} size={40} />
            </View>
          ))}
        </View>
      </View>
      <View style={styles.actions}>
        <Button
          label={strings.home.dropZone.sort}
          onPress={onSort}
          variant="secondary"
          size="sm"
          testID="drop-zone-open"
        />
        <Button
          label={strings.home.dropZone.quickSnap}
          onPress={onQuickSnap}
          icon="layers"
          variant="quiet"
          size="sm"
          testID="quick-snap"
        />
      </View>
    </Sheet>
  );
}

const styles = StyleSheet.create({
  head: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
  },
  headStacked: {
    flexDirection: 'column-reverse',
    gap: space.md,
  },
  text: {
    gap: space.xs,
  },
  textBeside: {
    flex: 1,
  },
  thumbs: {
    flexDirection: 'row',
  },
  ring: {
    borderWidth: RING,
    borderRadius: radius.thumb + RING,
    // The ring sits outside the thumb, so the stack lines up with the text.
    margin: -RING,
  },
  overlap: {
    marginStart: -16,
  },
  actions: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: space.sm,
    marginTop: space.md,
  },
});
