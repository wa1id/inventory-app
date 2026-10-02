import { memo, useState } from 'react';
import { StyleSheet, View } from 'react-native';

import type { ItemWithContext } from '@/db/types';
import { useLayoutScale } from '@/hooks/useLayoutScale';
import { useSavedQuantity } from '@/hooks/useSavedQuantity';
import { ago } from '@/i18n/format';
import { strings } from '@/i18n/strings';
import { useToast } from '@/providers/ToastProvider';
import { quantitySpoken, whereSpoken } from '@/ui/a11y';
import { AppText, Highlighted } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { IconButton } from '@/ui/components/IconButton';
import { LocationLine } from '@/ui/components/LocationLine';
import { QuantityChip } from '@/ui/components/QuantityChip';
import { QuantityStepper } from '@/ui/components/QuantityStepper';
import { Row } from '@/ui/components/Row';
import { SavedQuantityStepper } from '@/ui/components/SavedQuantityStepper';
import { Thumb } from '@/ui/components/Thumb';
import { animateNextLayout } from '@/ui/motion';
import { MIN_TOUCH_TARGET, ROW_MIN, ROW_MIN_PHOTO, ROW_PADDING, space } from '@/ui/theme';

export interface ItemRowProps {
  item: ItemWithContext;
  /** The second line: where it is, its category, or when it was added. */
  line?: 'where' | 'detail' | 'added';
  tool?: 'chip' | 'stepper' | 'file' | 'delete' | 'none';
  /** Search terms to mark in the name. */
  terms?: readonly string[];
  thumb?: 56 | 76;
  /** `chip` rows: the list keeps at most one row expanded. */
  expanded?: boolean;
  onToggleExpand?: (id: string) => void;
  onPress: (id: string) => void;
  onFile?: (id: string) => void;
  onDelete?: (id: string) => void;
  /**
   * Where a `chip` or `stepper` row reports a quantity that did not save, with
   * the sentence naming the item. Defaults to an error toast.
   */
  onQuantityError?: (message: string) => void;
  testID?: string;
}

function displayName(item: ItemWithContext): string {
  return item.name.trim() ? item.name : strings.entities.unnamedItem;
}

function ItemName({ item, terms }: { item: ItemWithContext; terms?: readonly string[] }) {
  if (!item.name.trim()) {
    return (
      <AppText variant="name" tone="graphite" weight={500}>
        {strings.entities.unnamedItem}
      </AppText>
    );
  }
  return terms && terms.length > 0 ? (
    <Highlighted variant="name" text={item.name} terms={terms} numberOfLines={3} />
  ) : (
    <AppText variant="name" numberOfLines={3}>
      {item.name}
    </AppText>
  );
}

/**
 * `count`: the quantity, folded in front of the line on rows whose end is
 * taken by a control ("×30 · 28 days ago"), so the text keeps that width.
 */
function SecondLine({
  item,
  line,
  count,
}: {
  item: ItemWithContext;
  line: ItemRowProps['line'];
  count?: number;
}) {
  if (line === 'where' || line === undefined) return <LocationLine place={item} size="row" />;
  const lead =
    count === undefined || count === 1 ? null : (
      <AppText variant="meta" weight={600} tone={count === 0 ? 'signal' : 'ink'}>
        {count === 0 ? strings.rows.noneLeft : strings.rows.times(count)}
      </AppText>
    );
  const when = ago(item.createdAt);
  const rest =
    line === 'detail'
      ? item.category
      : count === undefined
        ? strings.rows.added(when)
        : lead
          ? when
          : strings.rows.addedShort(when);
  if (!lead && !rest) return null;
  return (
    <AppText variant="meta" tone="graphite">
      {lead}
      {lead && rest ? strings.rows.separator : null}
      {rest}
    </AppText>
  );
}

/** "×4" or "None left" beside rows without a quantity control; nothing for one (desk). */
function QuantityBadge({ quantity }: { quantity: number }) {
  if (quantity === 1) return null;
  return (
    <AppText
      variant="aside"
      tone={quantity === 0 ? 'signal' : 'ink'}
      accessibilityElementsHidden
      importantForAccessibility="no"
    >
      {quantity === 0 ? strings.rows.noneLeft : strings.rows.times(quantity)}
    </AppText>
  );
}

function rowLabel(item: ItemWithContext, quantity: number): string {
  return strings.rows.itemA11y(displayName(item), whereSpoken(item), quantitySpoken(quantity));
}

/**
 * The small thumbnail (48) beside a stepper, and on every 56 row in the
 * stacked layout, so the name keeps the room.
 */
function thumbSize(thumb: 56 | 76, small: boolean): 48 | 56 | 76 {
  return thumb === 56 && small ? 48 : thumb;
}

/** Between the name and the chip that sits at the end of its line. */
const CHIP_CLEARANCE = space.sm + space.md - ROW_PADDING.end;

/** A row whose quantity is a chip that opens a large stepper under it. */
function ChipItemRow({
  item,
  line = 'where',
  terms,
  thumb = 56,
  expanded = false,
  onToggleExpand,
  onPress,
  onQuantityError,
  testID,
}: ItemRowProps) {
  const { stacked } = useLayoutScale();
  const name = item.name.trim() ? item.name : undefined;
  const toast = useToast();
  // The chip sits at the end of the name's line, not in a column of its own,
  // so where the item is (the answer) runs the full width under it.
  const [chipWidth, setChipWidth] = useState<number>(MIN_TOUCH_TARGET);
  // One hook per row, shared by the chip and the stepper so they never disagree.
  const { quantity, setQuantity, error } = useSavedQuantity(item, {
    onError: (kind) => {
      const message = strings.quantity.notSavedNamed(displayName(item), kind === 'offline');
      if (onQuantityError) onQuantityError(message);
      else toast.show({ message, tone: 'error' });
    },
  });

  function toggle() {
    animateNextLayout();
    onToggleExpand?.(item.id);
  }

  return (
    <Row
      onPress={() => onPress(item.id)}
      leading={<Thumb uri={item.photoThumbUri ?? item.photoUri} size={thumbSize(thumb, stacked)} />}
      tool={
        <View onLayout={(event) => setChipWidth(Math.ceil(event.nativeEvent.layout.width))}>
          <QuantityChip
            quantity={quantity}
            itemName={displayName(item)}
            itemId={item.id}
            expanded={expanded}
            onToggle={toggle}
          />
        </View>
      }
      toolAlign="top"
      below={
        expanded ? (
          <View style={[styles.below, stacked ? styles.belowStacked : null]}>
            <QuantityStepper
              value={quantity}
              onChange={setQuantity}
              size="large"
              itemName={name}
              error={error}
              testIDSuffix={item.id}
            />
            <Button
              label={strings.quantity.done}
              variant="quiet"
              size="sm"
              onPress={toggle}
              style={stacked ? null : styles.done}
            />
          </View>
        ) : null
      }
      minHeight={thumb === 76 ? ROW_MIN_PHOTO : ROW_MIN}
      accessibilityLabel={rowLabel(item, quantity)}
      accessibilityHint={strings.a11y.opensItem}
      testID={testID ?? `item-row-${item.id}`}
    >
      <View style={stacked ? null : { paddingEnd: chipWidth + CHIP_CLEARANCE }}>
        <ItemName item={item} terms={terms} />
      </View>
      <SecondLine item={item} line={line} />
    </Row>
  );
}

/** Every other row: a compact stepper, a "File…" button, a delete, or nothing. */
function PlainItemRow({
  item,
  line = 'where',
  tool = 'none',
  terms,
  thumb = 56,
  onPress,
  onFile,
  onDelete,
  onQuantityError,
  testID,
}: ItemRowProps) {
  const { stacked } = useLayoutScale();
  const name = displayName(item);
  const unnamed = !item.name.trim();
  // Beside "File…" or a delete, the count joins the second line rather than
  // taking width from the name; a stepper shows it already.
  const folded = tool === 'file' || tool === 'delete';

  const control =
    tool === 'stepper' ? (
      <SavedQuantityStepper
        item={item}
        size="compact"
        testIDSuffix={item.id}
        onError={onQuantityError ? (message) => onQuantityError(message) : undefined}
      />
    ) : tool === 'file' ? (
      <Button
        label={strings.rows.file}
        accessibilityLabel={strings.rows.fileA11y(name)}
        icon="move"
        variant="secondary"
        size="sm"
        onPress={() => onFile?.(item.id)}
        testID={`drop-zone-file-${item.id}`}
      />
    ) : tool === 'delete' ? (
      <IconButton
        icon="trash"
        accessibilityLabel={unnamed ? strings.rows.deletePhotoA11y : strings.rows.deleteA11y(name)}
        onPress={() => onDelete?.(item.id)}
        testID={`review-delete-${item.id}`}
      />
    ) : null;

  return (
    <Row
      onPress={() => onPress(item.id)}
      leading={
        <Thumb
          uri={item.photoThumbUri ?? item.photoUri}
          size={thumbSize(thumb, stacked || tool === 'stepper')}
        />
      }
      aside={tool === 'none' ? <QuantityBadge quantity={item.quantity} /> : null}
      tool={control}
      minHeight={thumb === 76 ? ROW_MIN_PHOTO : ROW_MIN}
      accessibilityLabel={rowLabel(item, item.quantity)}
      accessibilityHint={strings.a11y.opensItem}
      testID={testID ?? `item-row-${item.id}`}
    >
      <ItemName item={item} terms={terms} />
      <SecondLine item={item} line={line} count={folded ? item.quantity : undefined} />
    </Row>
  );
}

function ItemRowBase(props: ItemRowProps) {
  // Two components rather than a conditional hook: only chip rows own a quantity hook.
  return (props.tool ?? 'chip') === 'chip' ? (
    <ChipItemRow {...props} />
  ) : (
    <PlainItemRow {...props} />
  );
}

/**
 * An item in any list: the name over the answer to "where is it?", set the
 * same size so the answer is never the smallest thing on the row (`111b579`).
 *
 * The quantity control sits beside the pressable row, never inside it.
 * The whole row speaks as one sentence: name, where, how many. Memoised on
 * what it shows; parents pass stable handlers that take the id. The place is
 * compared too: renaming a space or container elsewhere does not touch the
 * item's `updatedAt`, and the row must still show the new name.
 */
export const ItemRow = memo(ItemRowBase, (prev, next) => {
  const a = prev.item;
  const b = next.item;
  return (
    a.id === b.id &&
    a.updatedAt === b.updatedAt &&
    a.quantity === b.quantity &&
    a.photoThumbUri === b.photoThumbUri &&
    a.photoUri === b.photoUri &&
    a.name === b.name &&
    a.category === b.category &&
    a.containerId === b.containerId &&
    a.containerName === b.containerName &&
    a.containerShortCode === b.containerShortCode &&
    a.spaceName === b.spaceName &&
    a.spaceColor === b.spaceColor &&
    prev.expanded === next.expanded &&
    (prev.terms ?? []).join() === (next.terms ?? []).join() &&
    prev.line === next.line &&
    prev.tool === next.tool &&
    prev.thumb === next.thumb &&
    prev.onPress === next.onPress &&
    prev.onToggleExpand === next.onToggleExpand &&
    prev.onFile === next.onFile &&
    prev.onDelete === next.onDelete &&
    prev.onQuantityError === next.onQuantityError &&
    prev.testID === next.testID
  );
});

const styles = StyleSheet.create({
  below: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: space.md,
    paddingStart: ROW_PADDING.start,
    paddingEnd: ROW_PADDING.end,
    paddingBottom: space.md,
  },
  // Buttons hold themselves to the start; beside the stepper, Done centres on it.
  done: {
    alignSelf: 'center',
  },
  // One column, not a wrapping one: a wrapping column sizes its line to the
  // widest child, so the stepper could not stretch to the row's width.
  belowStacked: {
    flexDirection: 'column',
    flexWrap: 'nowrap',
    alignItems: 'stretch',
  },
});
