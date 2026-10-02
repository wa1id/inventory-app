import { useState } from 'react';
import { ScrollView, StyleSheet } from 'react-native';
import { useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { LATEST_SCHEMA_VERSION } from '@/db/migrations';
import { strings } from '@/i18n/strings';
import { useConnection } from '@/providers/ConnectionProvider';
import { useHousehold } from '@/providers/HouseholdProvider';
import { useOnboarding } from '@/providers/OnboardingProvider';
import { useSync } from '@/providers/SyncProvider';
import { appVersion } from '@/services/appInfo';
import { appConfig } from '@/services/config';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { SettingsRow } from '@/ui/components/SettingsRow';
import { Section, Sheet, SheetSeparator } from '@/ui/components/Sheet';
import { serverHost } from '@/ui/household/join';
import { backupSummary, showBackupRow } from '@/ui/household/status';
import { animateNextLayout } from '@/ui/motion';
import { GUTTER, space } from '@/ui/theme';

/**
 * Settings: where this phone's household, backup, help and version live.
 * Rare, and mostly the owner's, so it sits behind one button on Home rather
 * than a tab (issue #2). Every row says its current state, and screen readers
 * hear it with the label (UX-17). Nothing here writes.
 *
 * The old "Your inventory" counts are gone: they read 0 while loading, offline
 * and for the drop zone (B12); Home's summary carries honest counts. Developer
 * facts sit behind "Technical details" instead of mixing with settings (UX-12).
 */
export default function SettingsScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { replay } = useOnboarding();
  const { status } = useSync();
  const { session } = useHousehold();
  const connection = useConnection();
  const [technical, setTechnical] = useState(false);

  const backup = backupSummary(status);
  const unreachable = session !== null && connection.state === 'offline';
  const householdValue = !session
    ? strings.settings.thisPhoneOnly
    : unreachable
      ? strings.settings.cantReach
      : strings.settings.joinedAs(session.deviceName);
  // The address in use when joined; the one this build would join otherwise (B10).
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
              tone={unreachable ? 'signal' : 'ink'}
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
                onPress={() => router.push('/backup')}
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
            <SettingsRow label={strings.settings.version} value={appVersion} />
            <SheetSeparator />
            <SettingsRow
              label={strings.settings.technical}
              expanded={technical}
              onPress={() => {
                animateNextLayout();
                setTechnical((open) => !open);
              }}
              testID="settings-technical"
            />
            {technical ? (
              <>
                <SheetSeparator />
                <SettingsRow label={strings.settings.environment} value={appConfig.environment} />
                <SheetSeparator />
                <SettingsRow
                  label={strings.settings.schema}
                  value={strings.settings.schemaValue(LATEST_SCHEMA_VERSION)}
                />
                <SheetSeparator />
                <SettingsRow
                  label={strings.settings.suggestions}
                  value={
                    appConfig.recognitionEndpoint
                      ? strings.settings.suggestionsOn
                      : strings.settings.suggestionsOff
                  }
                />
                <SheetSeparator />
                <SettingsRow label={strings.settings.serverAddress} value={serverAddress} />
              </>
            ) : null}
          </Sheet>
        </Section>
      </ScrollView>
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  content: {
    padding: GUTTER,
  },
});
