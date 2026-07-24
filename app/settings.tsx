import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';

import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { useRepositories } from '@/providers/DatabaseProvider';
import { LATEST_SCHEMA_VERSION } from '@/db/migrations';
import { appVersion } from '@/services/appInfo';
import { appConfig } from '@/services/config';
import { useOnboarding } from '@/providers/OnboardingProvider';
import { Screen } from '@/ui/components/Screen';
import { MIN_TOUCH_TARGET, radius, spacing, useTheme } from '@/ui/theme';

function Row({ label, value, onPress }: { label: string; value?: string; onPress?: () => void }) {
  const { colors } = useTheme();
  const content = (
    <View style={[styles.row, { borderColor: colors.border }]}>
      <Text style={[styles.rowLabel, { color: colors.text }]}>{label}</Text>
      {value ? <Text style={[styles.rowValue, { color: colors.textMuted }]}>{value}</Text> : null}
      {onPress ? <Text style={[styles.chevron, { color: colors.textMuted }]}>›</Text> : null}
    </View>
  );

  if (!onPress) return content;

  return (
    <Pressable onPress={onPress} accessibilityRole="button" accessibilityLabel={label}>
      {content}
    </Pressable>
  );
}

export default function SettingsScreen() {
  const router = useRouter();
  const repos = useRepositories();
  const { replay } = useOnboarding();
  const { colors } = useTheme();

  const { data: counts } = useInventoryQuery(async () => {
    const spaces = await repos.spaces.listWithCounts();
    return {
      spaces: spaces.length,
      containers: spaces.reduce((total, space) => total + space.containerCount, 0),
      items: spaces.reduce((total, space) => total + space.itemCount, 0),
    };
  }, 'inventory-counts');

  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <ScrollView contentContainerStyle={styles.content}>
        <View
          style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}
        >
          <Text style={[styles.sectionTitle, { color: colors.textMuted }]}>Your inventory</Text>
          <Row label="Spaces" value={String(counts?.spaces ?? 0)} />
          <Row label="Containers" value={String(counts?.containers ?? 0)} />
          <Row label="Items" value={String(counts?.items ?? 0)} />
        </View>

        <View
          style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}
        >
          <Text style={[styles.sectionTitle, { color: colors.textMuted }]}>Help</Text>
          <Row
            label="Replay the intro"
            onPress={async () => {
              await replay();
              router.replace('/onboarding');
            }}
          />
          <Row label="Privacy and your data" onPress={() => router.push('/privacy')} />
        </View>

        <View
          style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}
        >
          <Text style={[styles.sectionTitle, { color: colors.textMuted }]}>About</Text>
          <Row label="Version" value={appVersion} />
          <Row label="Environment" value={appConfig.environment} />
          <Row label="Database schema" value={`v${LATEST_SCHEMA_VERSION}`} />
          <Row
            label="Photo suggestions"
            value={appConfig.recognitionEndpoint ? 'Enabled' : 'Not configured'}
          />
        </View>
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: {
    padding: spacing.lg,
    gap: spacing.lg,
  },
  card: {
    borderRadius: radius.lg,
    borderWidth: 1,
    paddingHorizontal: spacing.md,
    paddingBottom: spacing.xs,
  },
  sectionTitle: {
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
    minHeight: MIN_TOUCH_TARGET,
    paddingVertical: spacing.sm,
    borderTopWidth: StyleSheet.hairlineWidth,
    gap: spacing.md,
  },
  rowLabel: {
    flex: 1,
    fontSize: 16,
  },
  rowValue: {
    fontSize: 16,
  },
  chevron: {
    fontSize: 22,
  },
});
