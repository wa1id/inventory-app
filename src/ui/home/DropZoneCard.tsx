import { StyleSheet, View } from 'react-native';

import type { ItemWithContext } from '@/db/types';
import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { Sheet } from '@/ui/components/Sheet';
import { Thumb } from '@/ui/components/Thumb';
import { space } from '@/ui/theme';

/** How many of the waiting items show a thumbnail on the card. */
const THUMBS = 4;

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
 * The card itself is not pressable: its two buttons sit side by side, so
 * Quick Snap is never a button inside a button (B11, the old card at
 * `app/(tabs)/index.tsx:112-142` hid it from VoiceOver). Shown only while
 * something is waiting, so a first run is not led by an empty inbox (UX-7).
 */
export function DropZoneCard({ items, count, onSort, onQuickSnap }: DropZoneCardProps) {
  return (
    <Sheet inset testID="drop-zone-card">
      <View style={styles.thumbs}>
        {items.slice(0, THUMBS).map((item) => (
          <Thumb key={item.id} uri={item.photoThumbUri ?? item.photoUri} size={48} />
        ))}
      </View>
      <View style={styles.text}>
        <AppText variant="section" accessibilityRole="header">
          {strings.home.dropZone.title(count)}
        </AppText>
        <AppText variant="meta" tone="graphite">
          {strings.home.dropZone.body}
        </AppText>
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
  thumbs: {
    flexDirection: 'row',
    gap: space.sm,
    marginBottom: space.md,
  },
  text: {
    gap: space.xs,
  },
  actions: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: space.sm,
    marginTop: space.lg,
  },
});
