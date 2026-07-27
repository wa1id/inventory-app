import { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Image,
  Pressable,
  SectionList,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useRouter } from 'expo-router';

import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import {
  formatLocationPath,
  type ItemSearchResult,
  type LocationSearchResult,
  type SearchResults,
} from '@/repositories/search';
import { logEvent } from '@/services/telemetry';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState, Screen } from '@/ui/components/Screen';
import { CONTAINER_ICONS, MIN_TOUCH_TARGET, onColor, radius, spacing, useTheme } from '@/ui/theme';

/** Short enough to feel instant, long enough to skip most intermediate keystrokes. */
const DEBOUNCE_MS = 200;

type Row =
  { type: 'location'; value: LocationSearchResult } | { type: 'item'; value: ItemSearchResult };

export default function SearchScreen() {
  const repos = useRepositories();
  const router = useRouter();
  const { colors } = useTheme();

  const [query, setQuery] = useState('');
  // The settled outcome carries the query it belongs to, which is what lets
  // `searching` be derived instead of stored — no state is written
  // synchronously inside the effect, only from its async callback.
  const [settled, setSettled] = useState<{
    query: string;
    results: SearchResults | null;
    error: string | null;
  }>({ query: '', results: null, error: null });

  const trimmed = query.trim();

  useEffect(() => {
    if (!trimmed) return;

    let cancelled = false;

    const timer = setTimeout(async () => {
      try {
        const found = await repos.search.search(trimmed);
        if (cancelled) return;
        setSettled({ query: trimmed, results: found, error: null });
        logEvent('search_performed', {
          termCount: found.terms.length,
          resultCount: found.items.length + found.locations.length,
          queryLength: trimmed.length,
        });
      } catch (cause) {
        if (cancelled) return;
        setSettled({
          query: trimmed,
          results: null,
          error: cause instanceof Error ? cause.message : 'Search could not be completed.',
        });
      }
    }, DEBOUNCE_MS);

    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [trimmed, repos]);

  const isCurrent = settled.query === trimmed;
  const results = isCurrent ? settled.results : null;
  const error = isCurrent ? settled.error : null;
  const searching = trimmed.length > 0 && !isCurrent;

  const sections: { title: string; data: Row[] }[] = [];

  if (results) {
    if (results.locations.length > 0) {
      sections.push({
        title: strings.search.locations,
        data: results.locations.map((value) => ({ type: 'location', value })),
      });
    }
    if (results.items.length > 0) {
      sections.push({
        title: strings.search.itemsHeading,
        data: results.items.map((value) => ({ type: 'item', value })),
      });
    }
  }

  const showNoResults =
    results !== null && results.locations.length === 0 && results.items.length === 0;

  return (
    <Screen edges={['left', 'right']}>
      <View
        style={[styles.searchBar, { backgroundColor: colors.surface, borderColor: colors.border }]}
      >
        <Text style={styles.searchGlyph} accessibilityElementsHidden importantForAccessibility="no">
          🔎
        </Text>
        <TextInput
          value={query}
          onChangeText={setQuery}
          placeholder={strings.search.placeholder}
          placeholderTextColor={colors.textMuted}
          style={[styles.input, { color: colors.text }]}
          accessibilityLabel={strings.search.placeholder}
          autoCorrect={false}
          autoCapitalize="none"
          returnKeyType="search"
          clearButtonMode="while-editing"
        />
        {searching ? <ActivityIndicator color={colors.textMuted} /> : null}
      </View>

      {error ? (
        <ErrorState message={error} onRetry={() => setQuery((value) => `${value} `.trim())} />
      ) : trimmed.length === 0 ? (
        <EmptyState icon="🔎" title={strings.search.idle.title} body={strings.search.idle.body} />
      ) : showNoResults ? (
        <EmptyState
          icon="🤷"
          title={strings.search.noResults.title}
          body={strings.search.noResults.body}
        />
      ) : (
        <SectionList
          sections={sections}
          keyExtractor={(row) => `${row.type}-${row.value.id}`}
          contentContainerStyle={styles.list}
          keyboardShouldPersistTaps="handled"
          renderSectionHeader={({ section }) => (
            <Text
              style={[
                styles.sectionHeader,
                { color: colors.textMuted, backgroundColor: colors.background },
              ]}
            >
              {section.title}
            </Text>
          )}
          renderItem={({ item: row }) =>
            row.type === 'location' ? (
              <LocationRow
                location={row.value}
                onPress={() =>
                  router.push(
                    row.value.kind === 'space'
                      ? `/space/${row.value.id}`
                      : `/container/${row.value.id}`,
                  )
                }
              />
            ) : (
              <ItemRow
                item={row.value}
                onOpenItem={() => router.push(`/item/${row.value.id}`)}
                onOpenContainer={() => router.push(`/container/${row.value.containerId}`)}
              />
            )
          }
        />
      )}
    </Screen>
  );
}

function LocationRow({
  location,
  onPress,
}: {
  location: LocationSearchResult;
  onPress: () => void;
}) {
  const { colors } = useTheme();

  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`${location.title}, ${location.subtitle}`}
      style={({ pressed }) => [
        styles.row,
        { backgroundColor: colors.surface, borderColor: colors.border, opacity: pressed ? 0.8 : 1 },
      ]}
    >
      <Text style={styles.rowGlyph}>{location.kind === 'space' ? '🏠' : '📦'}</Text>
      <View style={styles.rowBody}>
        <Text style={[styles.rowTitle, { color: colors.text }]} numberOfLines={1}>
          {location.title}
        </Text>
        <Text style={[styles.rowMeta, { color: colors.textMuted }]} numberOfLines={1}>
          {location.subtitle}
        </Text>
      </View>
      <Text style={[styles.chevron, { color: colors.textMuted }]}>›</Text>
    </Pressable>
  );
}

function ItemRow({
  item,
  onOpenItem,
  onOpenContainer,
}: {
  item: ItemSearchResult;
  onOpenItem: () => void;
  onOpenContainer: () => void;
}) {
  const { colors } = useTheme();

  return (
    <Pressable
      onPress={onOpenItem}
      accessibilityRole="button"
      accessibilityLabel={`${item.name}, stored in ${formatLocationPath(item)}${
        item.matchKind === 'location' ? `. ${strings.search.locationMatch}` : ''
      }`}
      style={({ pressed }) => [
        styles.row,
        { backgroundColor: colors.surface, borderColor: colors.border, opacity: pressed ? 0.8 : 1 },
      ]}
    >
      {item.photoUri ? (
        <Image
          source={{ uri: item.photoUri }}
          style={styles.thumb}
          accessibilityIgnoresInvertColors
        />
      ) : (
        <View
          style={[styles.thumb, styles.thumbPlaceholder, { backgroundColor: colors.surfaceAlt }]}
        >
          <Text style={styles.rowGlyph}>
            {CONTAINER_ICONS[item.containerName ? 'box' : 'other'] ?? '🧾'}
          </Text>
        </View>
      )}

      <View style={styles.rowBody}>
        <Text style={[styles.rowTitle, { color: colors.text }]} numberOfLines={1}>
          {item.name}
        </Text>

        {/* Tapping the location opens the container without redoing the
            search. The space reads as its own colour chip so a result is
            placed at a glance, the way the tile grid teaches it. */}
        <Pressable
          onPress={onOpenContainer}
          accessibilityRole="button"
          accessibilityLabel={`Open ${formatLocationPath(item)}`}
          hitSlop={spacing.sm}
          style={styles.location}
        >
          <View style={[styles.spacePill, { backgroundColor: item.spaceColor }]}>
            <Text
              style={[styles.spacePillText, { color: onColor(item.spaceColor) }]}
              numberOfLines={1}
            >
              {item.spaceIcon} {item.spaceName}
            </Text>
          </View>
          <Text style={[styles.containerLabel, { color: colors.textMuted }]} numberOfLines={1}>
            {item.containerName ?? item.containerShortCode}
          </Text>
        </Pressable>

        {item.matchKind === 'location' ? (
          <Text style={[styles.badge, { color: colors.textMuted }]}>
            {strings.search.locationMatch}
          </Text>
        ) : null}
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  searchBar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    margin: spacing.lg,
    marginBottom: spacing.sm,
    paddingHorizontal: spacing.md,
    borderRadius: radius.md,
    borderWidth: 1,
    minHeight: MIN_TOUCH_TARGET,
  },
  searchGlyph: {
    fontSize: 16,
  },
  input: {
    flex: 1,
    fontSize: 16,
    paddingVertical: spacing.md,
  },
  list: {
    paddingHorizontal: spacing.lg,
    paddingBottom: spacing.xxl,
    gap: spacing.sm,
  },
  sectionHeader: {
    fontSize: 13,
    fontWeight: '700',
    textTransform: 'uppercase',
    letterSpacing: 0.6,
    paddingTop: spacing.md,
    paddingBottom: spacing.sm,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    padding: spacing.sm,
    borderRadius: radius.lg,
    borderWidth: 1,
    minHeight: MIN_TOUCH_TARGET + spacing.sm,
  },
  rowGlyph: {
    fontSize: 22,
  },
  location: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    flexWrap: 'wrap',
  },
  spacePill: {
    paddingHorizontal: spacing.sm,
    paddingVertical: 2,
    borderRadius: radius.pill,
    maxWidth: '70%',
  },
  spacePillText: {
    fontSize: 13,
    fontWeight: '700',
  },
  containerLabel: {
    fontSize: 13,
    flexShrink: 1,
  },
  thumb: {
    width: 52,
    height: 52,
    borderRadius: radius.md,
  },
  thumbPlaceholder: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  rowBody: {
    flex: 1,
    gap: 2,
  },
  rowTitle: {
    fontSize: 16,
    fontWeight: '700',
  },
  rowMeta: {
    fontSize: 14,
  },
  path: {
    fontSize: 14,
    fontWeight: '600',
  },
  badge: {
    fontSize: 12,
    fontStyle: 'italic',
  },
  chevron: {
    fontSize: 24,
  },
});
