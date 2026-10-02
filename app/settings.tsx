import { useState } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import { useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { LATEST_SCHEMA_VERSION } from '@/db/migrations';
import { strings } from '@/i18n/strings';
import { useHousehold } from '@/providers/HouseholdProvider';
import { useOnboarding } from '@/providers/OnboardingProvider';
import { useSync } from '@/providers/SyncProvider';
import { appVersion } from '@/services/appInfo';
import { appConfig } from '@/services/config';
import { AppText } from '@/ui/components/AppText';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { SettingsRow } from '@/ui/components/SettingsRow';
import { Section, Sheet, SheetSeparator } from '@/ui/components/Sheet';
import { serverHost } from '@/ui/household/join';
import { backupSummary, showBackupRow } from '@/ui/household/status';
import { animateNextLayout } from '@/ui/motion';
import { GUTTER, ROW_GAP, ROW_PADDING, space } from '@/ui/theme';

/**
 * Settings: where this phone's household, backup, help and version live.
 * Rare, and mostly the owner's, so it sits behind one button on Home rather
 * than a tab (issue #2). Every row says its current state, and screen readers
 * hear it with the label. Nothing here writes.
 *
 * The old "Your inventory" counts are gone: they read 0 while loading, offline
 * and for the drop zone; Home's summary carries honest counts. Developer
 * facts sit behind "Technical details" instead of mixing with settings.
 */
export default function SettingsScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { replay } = useOnboarding();
  const { status } = useSync();
  const { session } = useHousehold();
  const [technical, setTechnical] = useState(false);

  const backup = backupSummary(status);
  // Always the name this phone joined as: an outage is said once, by the
  // connection banner above, not again in other words on this row.
  const householdValue = session
    ? strings.settings.joinedAs(session.deviceName)
    : strings.settings.thisPhoneOnly;
  // The address in use when joined; the one this build would join otherwise.
  const serverAddress = serverHost(session?.origin ?? appConfig.householdOrigin);

  return (
    <ScreenFrame kind="detail">
      <ScrollView
        contentContainerStyle={[styles.content, { paddingBottom: insets.bottom + space.xl }]}
      >
        <Section title={strings.settings.household} first>
          <Sheet>
            <SettingsRow
              icon="server"
              label={strings.settings.household}
              value={householdValue}
              onPress={() => router.push('/household')}
              testID="settings-household"
            />
          </Sheet>
        </Section>

        {showBackupRow(session !== null, status) ? (
          <Section title={strings.settings.onThisPhone}>
            <Sheet>
              <SettingsRow
                icon="backup"
                label={strings.settings.backup}
                value={backup.value}
                tone={backup.tone}
                // A build without a backup service has nothing to open: a
                // static row says so, rather than a page with one notice on it.
                onPress={status.state === 'unavailable' ? undefined : () => router.push('/backup')}
                testID="settings-backup"
              />
            </Sheet>
          </Section>
        ) : null}

        <Section title={strings.settings.help}>
          <Sheet>
            {/* Replaying flips the onboarding guard; the root stack swaps to the intro itself. */}
            <SettingsRow
              icon="info"
              label={strings.settings.howItWorks}
              onPress={() => void replay()}
              testID="settings-replay"
            />
            <SheetSeparator />
            <SettingsRow
              icon="shield"
              label={strings.settings.privacy}
              onPress={() => router.push('/privacy')}
              testID="settings-privacy"
            />
          </Sheet>
        </Section>

        <Section title={strings.settings.about}>
          <Sheet>
            <SettingsRow icon="phone" label={strings.settings.version} value={appVersion} />
            <SheetSeparator />
            <SettingsRow
              icon="settings"
              label={strings.settings.technical}
              expanded={technical}
              onPress={() => {
                animateNextLayout();
                setTechnical((open) => !open);
              }}
              testID="settings-technical"
            />
            {technical ? (
              <TechnicalFacts
                facts={[
                  { label: strings.settings.environment, value: appConfig.environment },
                  {
                    label: strings.settings.schema,
                    value: strings.settings.schemaValue(LATEST_SCHEMA_VERSION),
                  },
                  {
                    label: strings.settings.suggestions,
                    value: appConfig.recognitionEndpoint
                      ? strings.settings.suggestionsOn
                      : strings.settings.suggestionsOff,
                  },
                  { label: strings.settings.serverAddress, value: serverAddress },
                ]}
              />
            ) : null}
          </Sheet>
        </Section>
      </ScrollView>
    </ScreenFrame>
  );
}

/**
 * What "Technical details" opens: quiet label-and-value lines in the rows'
 * label column, so opening it never looks as if more settings appeared.
 */
function TechnicalFacts({ facts }: { facts: readonly { label: string; value: string }[] }) {
  return (
    <View style={styles.facts}>
      {facts.map((fact) => (
        // One stop each, label then value.
        <View key={fact.label} accessible>
          <AppText variant="meta" tone="graphite">
            {fact.label}
          </AppText>
          <AppText variant="meta">{fact.value}</AppText>
        </View>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  content: {
    padding: GUTTER,
  },
  facts: {
    // The label column of the rows above: their padding, 20 pt icon and gap.
    paddingStart: ROW_PADDING.start + 20 + ROW_GAP,
    paddingEnd: ROW_PADDING.end,
    paddingBottom: space.lg,
    gap: space.md,
  },
});
