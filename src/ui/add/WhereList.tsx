import { Fragment } from 'react';
import { View } from 'react-native';

import { strings } from '@/i18n/strings';
import { entryId, type WhereEntry } from '@/ui/add/addSheet';
import { spellCode } from '@/ui/a11y';
import { AppText } from '@/ui/components/AppText';
import { Icon } from '@/ui/components/Icon';
import { LocationLine } from '@/ui/components/LocationLine';
import type { PlaceOption } from '@/ui/components/PlacePicker';
import { Row } from '@/ui/components/Row';
import { Sheet, SheetSeparator } from '@/ui/components/Sheet';
import { TypeTile } from '@/ui/components/SpaceTile';
import { OPTION_MIN, useTheme } from '@/ui/theme';

export interface WhereListProps {
  entries: readonly WhereEntry[];
  /** The container id the item will be saved in (the drop zone's for the drop zone). */
  selectedId: string;
  onSelect: (entry: WhereEntry) => void;
  /** "Somewhere else…": the full place picker. */
  onMore: () => void;
}

function optionLabel(option: PlaceOption): string {
  return (
    option.name ??
    strings.entities.unnamedContainer(
      strings.entities.typeNames[option.visualType] ?? strings.entities.typeNames.other ?? '',
    )
  );
}

function entryTestID(entry: WhereEntry): string {
  if (entry.kind === 'dropZone') return 'item-where-drop-zone';
  return entry.source === 'recent'
    ? `item-where-recent-${entry.option.id}`
    : `item-where-${entry.option.id}`;
}

/**
 * "Where it goes" in the Add sheet: the few places someone adding a thing
 * actually means, one tap each, and "Somewhere else…" for the rest.
 *
 * Each container is written as its location (pip, space › container, tape),
 * the same answer every list gives, so "● Kitchen › Drawer by the oven" reads
 * the way it will read when she looks for it later. The drop zone is always
 * there: "somewhere" is a valid place (Q2). The options are one radio group;
 * "Somewhere else…" sits after it as a plain button.
 */
export function WhereList({ entries, selectedId, onSelect, onMore }: WhereListProps) {
  const { colors } = useTheme();

  return (
    <Sheet>
      <View accessibilityRole="radiogroup" accessibilityLabel={strings.add.where}>
        {entries.map((entry, index) => {
          const id = entryId(entry);
          const selected = id === selectedId;
          return (
            <Fragment key={`${entry.kind === 'dropZone' ? 'drop' : entry.source}-${id}`}>
              {index > 0 ? <SheetSeparator /> : null}
              <Row
                onPress={() => {
                  if (!selected) onSelect(entry);
                }}
                leading={
                  entry.kind === 'dropZone' ? (
                    <TypeTile type="other" icon="inbox" size={40} />
                  ) : (
                    <TypeTile type={entry.option.visualType} size={40} />
                  )
                }
                aside={selected ? <Icon name="check" size={20} color={colors.ink} /> : null}
                selected={selected}
                minHeight={OPTION_MIN}
                accessibilityRole="radio"
                accessibilityLabel={
                  entry.kind === 'dropZone'
                    ? `${strings.add.dropZone}, ${strings.add.sortLater}`
                    : strings.picker.optionA11y(
                        optionLabel(entry.option),
                        entry.option.spaceName,
                        spellCode(entry.option.shortCode),
                      )
                }
                testID={entryTestID(entry)}
              >
                {entry.kind === 'dropZone' ? (
                  <>
                    <AppText variant="name">{strings.add.dropZone}</AppText>
                    <AppText variant="meta" tone="graphite">
                      {strings.add.sortLater}
                    </AppText>
                  </>
                ) : (
                  <LocationLine
                    size="row"
                    place={{
                      containerId: entry.option.id,
                      containerName: entry.option.name,
                      containerShortCode: entry.option.shortCode,
                      spaceId: entry.option.spaceId,
                      spaceName: entry.option.spaceName,
                      spaceColor: entry.option.spaceColor,
                    }}
                  />
                )}
              </Row>
            </Fragment>
          );
        })}
      </View>
      <SheetSeparator />
      <Row
        onPress={onMore}
        chevron
        minHeight={OPTION_MIN}
        accessibilityLabel={strings.add.elsewhere}
        accessibilityHint={strings.add.elsewhereHint}
        testID="item-where-more"
      >
        <AppText variant="name" weight={500}>
          {strings.add.elsewhere}
        </AppText>
      </Row>
    </Sheet>
  );
}
