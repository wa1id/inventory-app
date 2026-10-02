import type { Ref } from 'react';
import { StyleSheet, View } from 'react-native';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { strings } from '@/i18n/strings';
import type { PlaceLike } from '@/ui/a11y';
import { AppText } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { LocationLine } from '@/ui/components/LocationLine';
import { Sheet } from '@/ui/components/Sheet';
import { Tape } from '@/ui/components/Tape';
import { space } from '@/ui/theme';

export interface WhereCardProps {
  place: PlaceLike;
  /** The item's name, for "Move “Cordless drill”…"; empty when it has none yet. */
  name: string;
  /** "Move…", or "File it…" while the item waits in the drop zone. */
  onMove: () => void;
  /** That button, so focus can move to "File it…" once the item is named. */
  actionRef?: Ref<View>;
}

/**
 * "Kept in": the answer to "where is it?", and the largest text on the item
 * screen (spec §5.10; `111b579`, "the answer was its smallest text").
 *
 * The space and the container are each a link, so either level is one tap
 * away; the card itself is not pressable. The label code is the tape on the
 * box, spoken letter by letter. Move sits on the card because moving is
 * changing this answer. An item in the drop zone says so plainly, never
 * "Drop zone › Drop zone", and offers "File it…" as the card's main action.
 */
export function WhereCard({ place, name, onMove, actionRef }: WhereCardProps) {
  const inDropZone = place.containerId === DROP_ZONE_CONTAINER_ID;

  return (
    <Sheet inset>
      <View
        role="group"
        accessibilityLabel={strings.a11y.whereItIs}
        style={styles.card}
        testID="where-card"
      >
        <AppText variant="factLabel" tone="graphite">
          {strings.where.keptIn}
        </AppText>
        <View>
          <LocationLine place={place} size="card" linked />
          {inDropZone ? (
            <AppText variant="meta" tone="graphite">
              {strings.where.notFiledNote}
            </AppText>
          ) : null}
        </View>
        <View style={styles.footer}>
          {inDropZone ? null : (
            // Tape holds itself to the start of its line; the wrapper centres it in the row.
            <View>
              <Tape code={place.containerShortCode} size="m" spoken />
            </View>
          )}
          <Button
            ref={actionRef}
            label={inDropZone ? strings.item.fileIt : strings.item.move}
            accessibilityLabel={
              inDropZone
                ? name
                  ? strings.item.fileItA11y(name)
                  : strings.item.fileItA11yUnnamed
                : name
                  ? strings.item.moveA11y(name)
                  : strings.item.moveA11yUnnamed
            }
            onPress={onMove}
            icon="move"
            size="sm"
            variant={inDropZone ? 'primary' : 'secondary'}
            testID={inDropZone ? 'item-file' : 'item-move'}
            style={styles.action}
          />
        </View>
      </View>
    </Sheet>
  );
}

const styles = StyleSheet.create({
  card: {
    gap: space.md,
  },
  footer: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: space.md,
  },
  action: {
    // The button sits at the end of the row, after the tape, or alone.
    marginStart: 'auto',
    alignSelf: 'center',
  },
});
