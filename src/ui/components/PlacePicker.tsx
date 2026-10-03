import { useMemo, useRef, useState, type ReactNode } from 'react';
import { ActivityIndicator, SectionList, StyleSheet, View } from 'react-native';
import { router } from 'expo-router';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { useRecentPlaces } from '@/hooks/useRecentPlaces';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import { spellCode } from '@/ui/a11y';
import { AppText } from '@/ui/components/AppText';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState } from '@/ui/components/ErrorState';
import { Icon } from '@/ui/components/Icon';
import { Row } from '@/ui/components/Row';
import { SearchField } from '@/ui/components/SearchField';
import { SheetSeparator, sheetCell } from '@/ui/components/Sheet';
import { Skeleton } from '@/ui/components/Skeleton';
import { SpacePip } from '@/ui/components/SpacePip';
import { TypeTile } from '@/ui/components/SpaceTile';
import { Tape } from '@/ui/components/Tape';
import { haptics } from '@/ui/haptics';
import type { NewContainerResult, NewSpaceResult } from '@/ui/navigation';
import {
  joinPlaceOptions,
  matchesPlace,
  placeTerms,
  toPlaceOption,
  type PlaceOption,
} from '@/ui/placeMatch';
import { openForResult } from '@/ui/routeResult';
import { GUTTER, OPTION_MIN, space, useTheme } from '@/ui/theme';

export type { PlaceOption } from '@/ui/placeMatch';

export type PickedPlace = { kind: 'dropZone' } | { kind: 'container'; option: PlaceOption };

export interface PlacePickerProps {
  /**
   * - `move` / `file`: the item's container is "Here now" and cannot be picked.
   * - `choose`: where a new item goes; the current choice is selected.
   * - `bind`: which container a new label belongs to.
   * - `open`: open a container by typing its label code.
   */
  mode: 'move' | 'file' | 'choose' | 'bind' | 'open';
  currentContainerId?: string;
  selectedContainerId?: string;
  /** `choose`: offer "Drop zone · Sort it later" first. */
  showDropZone?: boolean;
  /** Offer "New container in …" under each space. Default true except in `open`. */
  allowNewContainer?: boolean;
  /** Default true only in `open`, where typing the code is the whole point. */
  autoFocusFilter?: boolean;
  /** The filter's placeholder; `open` shows an example code instead of the general hint. */
  placeholder?: string;
  /**
   * The option showing a spinner while `onPick` runs (the drop zone's is its
   * container id); the list is locked meanwhile.
   */
  busyId?: string | null;
  /** A banner at the top (a conflict, a failure). */
  notice?: ReactNode;
  onPick: (place: PickedPlace) => void | Promise<void>;
}

/** Recent places shown above the spaces. */
const MAX_RECENT_SHOWN = 4;

type Entry =
  | { kind: 'option'; option: PlaceOption; recent: boolean }
  | { kind: 'dropZone' }
  /** `color`: in the one "Make a new container" list, where its space pip leads the row. */
  | { kind: 'newContainer'; spaceId: string; spaceName: string; color?: string };

interface PickerSection {
  key: string;
  kind: 'top' | 'recent' | 'space' | 'new';
  title?: string;
  color?: string;
  data: Entry[];
}

function unnamedLabel(option: PlaceOption): string {
  return strings.entities.unnamedContainer(
    strings.entities.typeNames[option.visualType] ?? strings.entities.typeNames.other ?? '',
  );
}

function optionLabel(option: PlaceOption): string {
  return option.name ?? unnamedLabel(option);
}

function byLabel(a: PlaceOption, b: PlaceOption): number {
  return (a.name ?? a.shortCode).localeCompare(b.name ?? b.shortCode, 'en', {
    sensitivity: 'base',
  });
}

/**
 * The one place picker: moving and filing an item, choosing where a new item
 * goes, binding a label to a container and opening a container by its code.
 *
 * Containers are grouped under their spaces, in the same order as the Spaces
 * tab, and sorted by name within each. The filter matches names, label codes
 * (with or without the hyphen), spaces and types, so "drw7k" finds DRW-7K2M.
 * Recent places come first. A container can be created from here without
 * losing the picker: "New container in …" opens the form and picks the new
 * container as soon as it exists.
 */
export function PlacePicker({
  mode,
  currentContainerId,
  selectedContainerId,
  showDropZone = false,
  allowNewContainer = mode !== 'open',
  autoFocusFilter = mode === 'open',
  placeholder = strings.picker.filter,
  busyId = null,
  notice,
  onPick,
}: PlacePickerProps) {
  const repos = useRepositories();
  const { colors } = useTheme();
  const [query, setQuery] = useState('');
  const recentIds = useRecentPlaces();
  /** A space or container form is open (or opening) for a pick. */
  const openingRef = useRef(false);

  const containers = useInventoryQuery(() => repos.containers.listAllWithSpace(), 'containers-all');
  const spaces = useInventoryQuery(() => repos.spaces.listWithCounts(), 'spaces');

  const options = useMemo(
    () => joinPlaceOptions(containers.data ?? [], spaces.data ?? []),
    [containers.data, spaces.data],
  );

  const filtering = query.trim().length > 0;

  const sections = useMemo(() => {
    const terms = placeTerms(query);
    const matching = filtering ? options.filter((option) => matchesPlace(option, terms)) : options;
    const result: PickerSection[] = [];

    if (!filtering && mode === 'choose' && showDropZone) {
      result.push({ key: 'top', kind: 'top', data: [{ kind: 'dropZone' }] });
    }

    if (!filtering) {
      const byId = new Map(options.map((option) => [option.id, option]));
      const recent = recentIds
        .map((id) => byId.get(id))
        .filter((option): option is PlaceOption => option !== undefined)
        .slice(0, MAX_RECENT_SHOWN);
      if (recent.length > 0) {
        result.push({
          key: 'recent',
          kind: 'recent',
          title: strings.picker.recent,
          data: recent.map((option) => ({ kind: 'option', option, recent: true })),
        });
      }
    }

    // Spaces in the Spaces tab's order; containers whose space is not in the
    // list (yet) still show, under their own space name.
    const order = (spaces.data ?? []).map((entry) => ({
      id: entry.id,
      name: entry.name,
      color: entry.color,
    }));
    for (const option of options) {
      if (!order.some((entry) => entry.id === option.spaceId)) {
        order.push({ id: option.spaceId, name: option.spaceName, color: option.spaceColor });
      }
    }

    // Nothing matches: one list of the spaces to make it in, rather than a
    // header and a one-row sheet per space.
    if (filtering && matching.length === 0) {
      if (allowNewContainer && order.length > 0) {
        result.push({
          key: 'new',
          kind: 'new',
          title: strings.picker.newContainerTitle,
          data: order.map((entry) => ({
            kind: 'newContainer',
            spaceId: entry.id,
            spaceName: entry.name,
            color: entry.color,
          })),
        });
      }
      return result;
    }

    for (const entry of order) {
      const inSpace = matching.filter((option) => option.spaceId === entry.id).sort(byLabel);
      const offerNew = allowNewContainer && (!filtering || inSpace.length > 0);
      if (inSpace.length === 0 && !offerNew) continue;
      const data: Entry[] = inSpace.map((option) => ({ kind: 'option', option, recent: false }));
      if (offerNew) data.push({ kind: 'newContainer', spaceId: entry.id, spaceName: entry.name });
      result.push({ key: entry.id, kind: 'space', title: entry.name, color: entry.color, data });
    }
    return result;
  }, [allowNewContainer, filtering, mode, options, query, recentIds, showDropZone, spaces.data]);

  /**
   * Opens a form that answers, one at a time: a second tap before the first
   * form is up would stack another (as the Add sheet's camera guards).
   */
  async function openOnce<T>(open: (request: string) => void): Promise<T | undefined> {
    if (openingRef.current) return undefined;
    openingRef.current = true;
    try {
      return await openForResult<T>(open);
    } finally {
      openingRef.current = false;
    }
  }

  /**
   * The form hands back what the picker shows of the new container, so it is
   * picked without reading it back over the network.
   */
  async function newContainer(spaceId: string, spaceName: string) {
    if (busyId !== null) return;
    const created = await openOnce<NewContainerResult>((request) =>
      router.push({ pathname: '/container/new', params: { spaceId, request } }),
    );
    if (!created) return;
    // The spaces list may not have the space yet (just made from here).
    const home = spaces.data?.find((entry) => entry.id === created.spaceId);
    await onPick({
      kind: 'container',
      option: toPlaceOption(
        {
          id: created.containerId,
          name: created.name,
          shortCode: created.shortCode,
          visualType: created.visualType,
          spaceId: created.spaceId,
          spaceName: home?.name ?? spaceName,
          itemCount: 0,
        },
        home,
      ),
    });
  }

  /**
   * No spaces at all: make one, then a container in it, and pick that, so a
   * sheet waiting for a place ends with one. Where nothing is waiting (opening
   * a container by its code) the new space simply opens.
   */
  async function newSpace() {
    if (!allowNewContainer) {
      router.push('/space/new');
      return;
    }
    if (busyId !== null) return;
    const created = await openOnce<NewSpaceResult>((request) =>
      router.push({ pathname: '/space/new', params: { request } }),
    );
    if (created) await newContainer(created.spaceId, created.name);
  }

  function pick(place: PickedPlace) {
    // Locked while a pick saves; a screen reader can still activate a row.
    if (busyId !== null) return;
    haptics.choice();
    void onPick(place);
  }

  function reload() {
    containers.reload();
    spaces.reload();
  }

  const loading =
    (containers.loading && containers.data === null) || (spaces.loading && spaces.data === null);
  const failure =
    containers.data === null && containers.cause
      ? containers.cause
      : spaces.data === null
        ? spaces.cause
        : null;
  const nothingAtAll =
    !loading && options.length === 0 && (!allowNewContainer || (spaces.data ?? []).length === 0);

  const filter = (
    <View style={styles.filter}>
      <SearchField
        value={query}
        onChangeText={setQuery}
        size="regular"
        placeholder={placeholder}
        accessibilityLabel={strings.picker.filterA11y}
        autoFocus={autoFocusFilter}
        autoCapitalize={mode === 'open' ? 'characters' : 'none'}
        testID="place-filter"
      />
    </View>
  );

  const header = (
    <>
      {notice ? <View style={styles.notice}>{notice}</View> : null}
      {/* The drop zone has no header of its own; this keeps it off the filter. */}
      {!notice && sections[0]?.kind === 'top' ? <View style={styles.topGap} /> : null}
      {filtering && options.length > 0 && !sections.some(hasOption) ? (
        <AppText variant="meta" tone="graphite" style={styles.noMatch}>
          {strings.picker.noMatch(query.trim())}
        </AppText>
      ) : null}
    </>
  );

  let body: ReactNode;
  if (loading) {
    body = (
      <View style={styles.state}>
        <Skeleton variant="options" />
      </View>
    );
  } else if (failure) {
    body = <ErrorState cause={failure} onRetry={reload} />;
  } else {
    body = (
      <SectionList
        sections={sections}
        keyExtractor={(entry) => entryKey(entry)}
        stickySectionHeadersEnabled
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="on-drag"
        ListHeaderComponent={header}
        ListFooterComponent={
          nothingAtAll ? (
            // The list already has the gutter; the empty state brings its own.
            <View style={styles.flush}>
              <EmptyState
                title={strings.picker.none.title}
                body={strings.picker.none.body}
                action={{
                  label: strings.picker.none.action,
                  onPress: () => void newSpace(),
                  testID: 'move-no-containers',
                }}
              />
            </View>
          ) : null
        }
        renderSectionHeader={({ section }) => <SectionHeader section={section} />}
        renderSectionFooter={() => <View style={styles.sectionGap} />}
        ItemSeparatorComponent={SheetSeparator}
        renderItem={({ item, index, section }) => (
          <View style={sheetCell(index, section.data.length, colors)}>
            <EntryRow
              entry={item}
              mode={mode}
              currentContainerId={currentContainerId}
              selectedContainerId={selectedContainerId}
              busyId={busyId}
              onPick={pick}
              onNewContainer={(spaceId, spaceName) => void newContainer(spaceId, spaceName)}
            />
          </View>
        )}
        contentContainerStyle={styles.list}
        style={busyId ? styles.busy : null}
        pointerEvents={busyId ? 'none' : 'auto'}
      />
    );
  }

  return (
    <View style={styles.picker}>
      {filter}
      {body}
    </View>
  );
}

function hasOption(section: PickerSection): boolean {
  return section.data.some((entry) => entry.kind === 'option');
}

function entryKey(entry: Entry): string {
  if (entry.kind === 'dropZone') return DROP_ZONE_CONTAINER_ID;
  if (entry.kind === 'newContainer') return `new-${entry.spaceId}`;
  return `${entry.recent ? 'recent' : 'space'}-${entry.option.id}`;
}

function SectionHeader({ section }: { section: PickerSection }) {
  const { colors } = useTheme();
  if (section.kind === 'top') return null;
  return (
    <View style={[styles.sectionHeader, { backgroundColor: colors.plaster }]}>
      {section.kind === 'recent' ? (
        <Icon name="clock" size={16} color={colors.graphite} />
      ) : section.kind === 'new' ? (
        <Icon name="plus" size={16} color={colors.graphite} />
      ) : (
        <SpacePip color={section.color} size={12} />
      )}
      {/* The header trait on the text itself: a plain View's is ignored, so
          the screen reader's headings list would be empty. */}
      <AppText
        variant="label"
        accessibilityRole="header"
        numberOfLines={2}
        style={styles.sectionTitle}
      >
        {section.title}
      </AppText>
    </View>
  );
}

interface EntryRowProps {
  entry: Entry;
  mode: PlacePickerProps['mode'];
  currentContainerId?: string;
  selectedContainerId?: string;
  busyId: string | null;
  onPick: (place: PickedPlace) => void;
  onNewContainer: (spaceId: string, spaceName: string) => void;
}

function EntryRow({
  entry,
  mode,
  currentContainerId,
  selectedContainerId,
  busyId,
  onPick,
  onNewContainer,
}: EntryRowProps) {
  const { colors } = useTheme();
  // While a pick saves, the other rows say they are unavailable and the
  // picked one says it is busy (it stays enabled, so it is not "dimmed").
  const locked = busyId !== null;
  const check = <Icon name="check" size={20} color={colors.ink} />;

  if (entry.kind === 'dropZone') {
    // Adding defaults to the drop zone: "somewhere" is a valid place.
    const selected =
      selectedContainerId === undefined || selectedContainerId === DROP_ZONE_CONTAINER_ID;
    const busy = busyId === DROP_ZONE_CONTAINER_ID;
    return (
      <Row
        onPress={() => onPick({ kind: 'dropZone' })}
        leading={<TypeTile type="other" icon="inbox" size={40} />}
        aside={busy ? <ActivityIndicator color={colors.graphite} /> : selected ? check : null}
        selected={selected}
        disabled={locked && !busy}
        accessibilityState={{ busy }}
        minHeight={OPTION_MIN}
        accessibilityRole="radio"
        accessibilityLabel={`${strings.picker.dropZone}, ${strings.picker.sortLater}`}
        testID="place-drop-zone"
      >
        <AppText variant="name">{strings.picker.dropZone}</AppText>
        <AppText variant="meta" tone="graphite">
          {strings.picker.sortLater}
        </AppText>
      </Row>
    );
  }

  if (entry.kind === 'newContainer') {
    const label = strings.picker.newContainerIn(entry.spaceName);
    return (
      <Row
        onPress={() => onNewContainer(entry.spaceId, entry.spaceName)}
        leading={
          <View style={styles.plus}>
            {entry.color !== undefined ? (
              <SpacePip color={entry.color} size={12} />
            ) : (
              <Icon name="plus" size={20} color={colors.ink} />
            )}
          </View>
        }
        disabled={locked}
        minHeight={OPTION_MIN}
        accessibilityLabel={label}
        testID={`place-new-container-${entry.spaceId}`}
      >
        <AppText variant="name" weight={500}>
          {label}
        </AppText>
      </Row>
    );
  }

  const { option } = entry;
  const label = optionLabel(option);
  const hereNow = (mode === 'move' || mode === 'file') && option.id === currentContainerId;
  const selected = mode === 'choose' && option.id === selectedContainerId;
  const spelled = spellCode(option.shortCode);
  const busy = busyId === option.id;

  return (
    <Row
      onPress={() => onPick({ kind: 'container', option })}
      leading={<TypeTile type={option.visualType} size={40} />}
      aside={
        busy ? (
          <ActivityIndicator color={colors.graphite} />
        ) : (
          // Tape holds itself to the start of its line; the wrapper centres it in the row.
          <View style={styles.aside}>
            <Tape code={option.shortCode} />
            {selected ? check : null}
          </View>
        )
      }
      selected={selected}
      disabled={hereNow || (locked && !busy)}
      accessibilityState={{ busy }}
      minHeight={OPTION_MIN}
      accessibilityRole={mode === 'choose' ? 'radio' : 'button'}
      accessibilityLabel={
        hereNow
          ? strings.picker.hereNowA11y(label)
          : strings.picker.optionA11y(label, option.spaceName, spelled)
      }
      testID={entry.recent ? `place-recent-${option.id}` : `move-to-${option.id}`}
    >
      {option.name ? (
        <AppText variant="name" tone={hereNow ? 'graphite' : 'ink'}>
          {option.name}
        </AppText>
      ) : (
        // Called what its own screen calls it; the tape at the end carries the code.
        <AppText variant="name" tone="graphite" weight={500}>
          {unnamedLabel(option)}
        </AppText>
      )}
      {entry.recent ? (
        <AppText variant="caption" tone="graphite">
          {option.spaceName}
        </AppText>
      ) : null}
      {hereNow ? (
        <AppText variant="caption" tone="graphite">
          {strings.picker.hereNow}
        </AppText>
      ) : null}
    </Row>
  );
}

const styles = StyleSheet.create({
  picker: {
    flex: 1,
  },
  filter: {
    paddingHorizontal: GUTTER,
    paddingTop: space.sm,
    paddingBottom: space.sm,
  },
  notice: {
    paddingBottom: space.md,
  },
  topGap: {
    height: space.sm,
  },
  flush: {
    marginHorizontal: -GUTTER,
  },
  noMatch: {
    paddingBottom: space.md,
  },
  state: {
    paddingHorizontal: GUTTER,
    paddingTop: space.sm,
  },
  list: {
    paddingHorizontal: GUTTER,
    paddingBottom: space.xxl,
  },
  busy: {
    opacity: 0.6,
  },
  sectionHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    minHeight: 40,
    paddingVertical: space.xs,
  },
  sectionTitle: {
    flexShrink: 1,
  },
  sectionGap: {
    height: space.lg,
  },
  plus: {
    width: 40,
    height: 40,
    alignItems: 'center',
    justifyContent: 'center',
  },
  aside: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
  },
});
