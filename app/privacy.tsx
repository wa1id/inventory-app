import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { MAX_IMAGE_DIMENSION } from '@/services/capture/imageScaling';
import { appConfig } from '@/services/config';
import { Screen } from '@/ui/components/Screen';
import { radius, spacing, useTheme } from '@/ui/theme';

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  const { colors } = useTheme();
  return (
    <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
      <Text style={[styles.title, { color: colors.text }]} accessibilityRole="header">
        {title}
      </Text>
      {children}
    </View>
  );
}

function Body({ children }: { children: React.ReactNode }) {
  const { colors } = useTheme();
  return <Text style={[styles.body, { color: colors.textMuted }]}>{children}</Text>;
}

/**
 * In-app privacy notice covering camera and gallery data handling and
 * retention, required before beta (issue #8).
 */
export default function PrivacyScreen() {
  return (
    <Screen edges={['left', 'right', 'bottom']}>
      <ScrollView contentContainerStyle={styles.content}>
        <Section title="Where your inventory lives">
          <Body>
            Spaces, containers, items, notes, and photos are stored in a database on this phone.
            That copy is the one the app reads from, and everything keeps working with no network at
            all.
          </Body>
          {appConfig.syncEndpoint ? (
            <Body>
              Backup is off unless you turn it on. If you do, a copy of that database and your
              photos is uploaded so you can get them back after losing or replacing this phone. If
              you leave it off, nothing is uploaded and uninstalling the app deletes everything.
            </Body>
          ) : (
            <Body>
              This build has no backup service configured, so nothing is uploaded anywhere.
              Uninstalling the app deletes all of it.
            </Body>
          )}
        </Section>

        {appConfig.syncEndpoint ? (
          <Section title="If you turn on backup">
            <Body>
              There is no account, no email address, and no password. The app generates a recovery
              code on this device and stores your backup under a name derived from it. That code is
              the only way to reach the backup — including for us. It is not recoverable, and if you
              lose it the backup cannot be opened by anyone, including you.
            </Body>
            <Body>
              Anyone who has the code can read that inventory, so it is worth treating like a
              password. Uploads travel over an encrypted connection. Your five most recent database
              snapshots are kept, so a mistake you notice later can still be undone.
            </Body>
            <Body>
              Turning backup on does not change what is on this phone. Deleting an item deletes the
              stored copy of its photo too.
            </Body>
          </Section>
        ) : null}

        <Section title="Camera and photos">
          <Body>
            The camera is used for two things: photographing an item you are adding, and scanning a
            QR label. Photos you take in the app are saved to the app&apos;s own private storage —
            not to your camera roll. Importing a photo copies it; the original is left untouched.
            Each photo is resized to at most {MAX_IMAGE_DIMENSION} pixels on its long edge and
            re-encoded as a WebP image before it is saved, alongside a small thumbnail used in
            lists.
          </Body>
          <Body>
            Deleting an item, its container, or its space also deletes the photo file from this
            device.
          </Body>
        </Section>

        <Section title="Photo suggestions">
          {appConfig.recognitionEndpoint ? (
            <>
              <Body>
                When you add an item with a photo, that single image is sent to our service to
                suggest a name, category, and tags. The suggestion is only a suggestion — you can
                edit or ignore it, and saving an item never requires it.
              </Body>
              <Body>
                Images are sent for that one request and are not used to build a profile of you.
                Your notes and other item details are never sent.
              </Body>
            </>
          ) : (
            <Body>
              Photo suggestions are not configured in this build, so no image ever leaves this
              device. Items are always added by typing the details.
            </Body>
          )}
        </Section>

        <Section title="Diagnostics">
          <Body>
            Diagnostic events record only timings and outcome categories — how long something took
            and whether it succeeded. Item names, notes, photos, search text, and QR codes are
            filtered out before anything is recorded, and no crash or analytics provider is enabled
            in this build.
          </Body>
        </Section>

        <Section title="Working offline">
          <Body>
            Everything except photo suggestions and backup works with no network connection at all,
            including adding items, scanning labels, and searching. Backups wait for a connection
            and catch up on their own; nothing you do is blocked while they wait.
          </Body>
        </Section>
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  content: {
    padding: spacing.lg,
    gap: spacing.md,
    paddingBottom: spacing.xxl,
  },
  card: {
    borderRadius: radius.lg,
    borderWidth: 1,
    padding: spacing.lg,
    gap: spacing.sm,
  },
  title: {
    fontSize: 17,
    fontWeight: '700',
  },
  body: {
    fontSize: 15,
    lineHeight: 22,
  },
});
