import { StyleSheet, View } from 'react-native';

import type { Container, SpaceWithCounts } from '@/db/types';
import { strings } from '@/i18n/strings';
import type { LocationSearchResult } from '@/repositories/search';
import { spellCode } from '@/ui/a11y';
import { AppText } from '@/ui/components/AppText';
import { LocationLine } from '@/ui/components/LocationLine';
import { Row } from '@/ui/components/Row';
import { SpaceTile, TypeTile } from '@/ui/components/SpaceTile';
import { Tape } from '@/ui/components/Tape';
import { space } from '@/ui/theme';

export interface SpaceRowProps {
  space: SpaceWithCounts;
  /** Absent for the space form's live preview, which is static and has no chevron. */
  onPress?: (id: string) => void;
  /** The surface the row sits on, for the tile's tint. */
  surface?: 'sheet' | 'plaster';
  /** 56 on the Spaces tab, 48 in search results. */
  tileSize?: 48 | 56;
}

/** A space: its tile, its name, and how much is in it. */
export function SpaceRow({
  space: item,
  onPress,
  surface = 'sheet',
  tileSize = 56,
}: SpaceRowProps) {
  const counts = strings.entities.spaceCounts(item.containerCount, item.itemCount);
  return (
    <Row
      onPress={onPress ? () => onPress(item.id) : undefined}
      leading={<SpaceTile icon={item.icon} color={item.color} size={tileSize} surface={surface} />}
      chevron={Boolean(onPress)}
      accessibilityLabel={strings.rows.spaceA11y(item.name, counts)}
      testID={`space-row-${item.id}`}
    >
      <AppText variant="name">{item.name}</AppText>
      <AppText variant="meta" tone="graphite">
        {counts}
      </AppText>
    </Row>
  );
}

export interface ContainerRowData {
  id: string;
  name: string | null;
  shortCode: string;
  visualType: string;
  itemCount: number;
  qrToken?: string | null;
  spaceId?: string;
  spaceName?: string;
  spaceColor?: string;
}

export interface ContainerRowProps {
  container: ContainerRowData;
  /** In a space the meta is its contents; in search it is where the container is. */
  context: 'space' | 'search';
  onPress: (id: string) => void;
}

function typeName(visualType: string): string {
  return strings.entities.typeNames[visualType] ?? strings.entities.typeNames.other ?? visualType;
}

/** A container: its type, its name followed by its label tape. Unnamed ones show the tape alone. */
export function ContainerRow({ container, context, onPress }: ContainerRowProps) {
  const type = typeName(container.visualType);
  const items = strings.entities.items(container.itemCount);
  const label = container.name ?? strings.entities.unnamedContainer(type);
  const inSearch = context === 'search';

  return (
    <Row
      onPress={() => onPress(container.id)}
      leading={<TypeTile type={container.visualType} size={48} />}
      aside={
        inSearch ? (
          <AppText variant="meta" tone="graphite">
            {items}
          </AppText>
        ) : null
      }
      chevron
      accessibilityLabel={strings.rows.containerA11y(
        label,
        type,
        spellCode(container.shortCode),
        items,
        Boolean(container.qrToken),
      )}
      testID={`container-row-${container.id}`}
    >
      <View style={styles.nameLine}>
        {container.name ? (
          <AppText variant="name" style={styles.name}>
            {container.name}
          </AppText>
        ) : null}
        <Tape code={container.shortCode} size="s" />
      </View>
      {inSearch ? (
        container.spaceName ? (
          <LocationLine
            place={{
              containerId: container.id,
              containerName: container.name,
              containerShortCode: container.shortCode,
              spaceId: container.spaceId ?? '',
              spaceName: container.spaceName,
              spaceColor: container.spaceColor ?? '',
            }}
            size="inline"
            showContainer={false}
          />
        ) : null
      ) : (
        <AppText variant="meta" tone="graphite">
          {container.qrToken ? `${items} · ${strings.rows.qrLabel}` : items}
        </AppText>
      )}
    </Row>
  );
}

export type ContainerWithSpace = Container & { spaceName: string; itemCount: number };

export interface PlaceRowProps {
  hit: LocationSearchResult;
  /** From `spaces.listWithCounts()`, by id: colour and icon. */
  spaces: ReadonlyMap<string, SpaceWithCounts>;
  /** From `containers.listAllWithSpace()`, by id: code and type. */
  containers: ReadonlyMap<string, ContainerWithSpace>;
  onPress: (hit: LocationSearchResult) => void;
}

/**
 * A space or container that matched a search, drawn like it is everywhere
 * else by joining the hit with the full lists. If a join is missing (a list
 * still loading, a place created a moment ago) the hit's own title and
 * subtitle are shown, so a row is never blank; the preformatted subtitle is
 * shown as is and never parsed.
 */
export function PlaceRow({ hit, spaces, containers, onPress }: PlaceRowProps) {
  const testID = `place-row-${hit.id}`;
  const space = spaces.get(hit.kind === 'space' ? hit.id : hit.spaceId);

  if (hit.kind === 'space' && space) {
    return (
      <View testID={testID}>
        <SpaceRow space={space} onPress={() => onPress(hit)} tileSize={48} />
      </View>
    );
  }

  const container = hit.kind === 'container' ? containers.get(hit.id) : undefined;
  if (container) {
    return (
      <View testID={testID}>
        <ContainerRow
          container={{
            id: container.id,
            name: container.name,
            shortCode: container.shortCode,
            visualType: container.visualType,
            itemCount: hit.itemCount,
            spaceId: container.spaceId,
            spaceName: container.spaceName,
            spaceColor: space?.color,
          }}
          context="search"
          onPress={() => onPress(hit)}
        />
      </View>
    );
  }

  return (
    <Row
      onPress={() => onPress(hit)}
      leading={<TypeTile type="other" size={48} />}
      chevron
      accessibilityLabel={`${hit.title}. ${hit.subtitle}`}
      testID={testID}
    >
      <AppText variant="name">{hit.title}</AppText>
      <AppText variant="meta" tone="graphite">
        {hit.subtitle}
      </AppText>
    </Row>
  );
}

const styles = StyleSheet.create({
  nameLine: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    columnGap: space.sm,
    rowGap: space.xxs,
  },
  name: {
    flexShrink: 1,
  },
});
