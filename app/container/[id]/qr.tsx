import { useRef, useState } from 'react';
import { ActivityIndicator, Platform, ScrollView, Share, StyleSheet, View } from 'react-native';
import { Stack, router, useLocalSearchParams } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import type { QrBinding } from '@/db/types';
import { useInventoryQuery, type QueryResult } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useToast } from '@/providers/ToastProvider';
import { formatQrPayload } from '@/repositories/qr';
import { logEvent } from '@/services/telemetry';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { Button } from '@/ui/components/Button';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState } from '@/ui/components/ErrorState';
import { Row } from '@/ui/components/Row';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { Section, Sheet, SheetSeparator } from '@/ui/components/Sheet';
import { Skeleton } from '@/ui/components/Skeleton';
import { confirm } from '@/ui/confirm';
import { QrCard } from '@/ui/container/QrCard';
import {
  labelFailureMessage,
  settleWrittenLabel,
  shareText,
  type LabelAction,
  type WrittenLabel,
} from '@/ui/container/containerRules';
import { writeLabelPicture, type QrSvg } from '@/ui/container/labelImage';
import { haptics } from '@/ui/haptics';
import { goToTab } from '@/ui/navigation';
import { needsRefreshBanner } from '@/ui/spaces/spaceSetup';
import { GUTTER, OPTION_MIN, space, useTheme } from '@/ui/theme';

type Busy = LabelAction | 'share';

/**
 * The label on screen follows what was just written, from the moment the
 * write returns until a read set off afterwards has come back, so making,
 * replacing or removing a label never flashes the previous state in between
 * (where a second tap on "Make a QR label" would silently replace a fresh
 * label), and a read that fails never brings back a retired sticker.
 */
function useShownToken(binding: QueryResult<QrBinding | null>) {
  const [written, setWritten] = useState<WrittenLabel | null>(null);
  // Derived state, as in `useInventoryQuery`: wait for a reload to start, then to succeed.
  const next = settleWrittenLabel(written, {
    loading: binding.loading,
    failed: Boolean(binding.cause),
  });
  if (next !== written) setWritten(next);
  return {
    token: next ? next.token : (binding.data?.token ?? null),
    /** The screen shows its own write, which no failed read can contradict. */
    known: next !== null,
    wrote: (token: string | null) => setWritten({ token, reloading: false }),
  };
}

export default function ContainerQrScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  return (
    <ScreenFrame kind="detail">
      <Stack.Screen options={{ title: strings.qr.title }} />
      {id === DROP_ZONE_CONTAINER_ID ? <DropZoneLocked /> : <QrLabel id={id} />}
    </ScreenFrame>
  );
}

/** The drop zone is a tab, not a box with a sticker on it (B4, entities §15.1). */
function DropZoneLocked() {
  return (
    <EmptyState
      icon="inbox"
      title={strings.errors.dropZoneLocked.title}
      body={strings.errors.dropZoneLocked.body}
      action={{
        label: strings.errors.dropZoneLocked.action,
        onPress: () => goToTab('/drop-zone'),
      }}
    />
  );
}

/**
 * A container's QR label: show it to print or share; replace or remove it
 * when the sticker is lost; or make one, or link a sticker printed earlier.
 *
 * Nothing shows until both the container and its label have been read: the
 * old screen showed "No label yet" while the label was still loading, and a
 * tap on "Generate" then silently retired a printed sticker (entities §15.2,
 * capture §13.14). Every write is caught and told (entities §15.5, §13.3).
 */
function QrLabel({ id }: { id: string }) {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const toast = useToast();
  const insets = useSafeAreaInsets();

  const containerQuery = useInventoryQuery(() => repos.containers.getById(id), `container:${id}`);
  const binding = useInventoryQuery(() => repos.qr.getByContainer(id), `qr-of:${id}`);
  const shown = useShownToken(binding);

  // Whether the label has been read successfully at least once. Until then
  // the screen cannot say there is no label; afterwards a reload keeps what
  // is on screen rather than going back to the skeleton.
  const [labelKnown, setLabelKnown] = useState(false);
  if (!labelKnown && !binding.loading && !binding.cause) setLabelKnown(true);

  const [busy, setBusy] = useState<Busy | null>(null);
  const busyRef = useRef(false);
  const svgRef = useRef<QrSvg | null>(null);

  function begin(action: Busy): boolean {
    if (busyRef.current) return false;
    busyRef.current = true;
    setBusy(action);
    return true;
  }
  function end() {
    busyRef.current = false;
    setBusy(null);
  }

  function reloadAll() {
    containerQuery.reload();
    binding.reload();
  }

  /**
   * Makes a label (none yet) or replaces it (asked first): a fresh token is
   * bound, and the old one, if any, stops opening this container.
   */
  async function makeLabel(action: 'make' | 'replace') {
    if (!begin(action)) return;
    try {
      if (action === 'replace') {
        const confirmed = await confirm({
          title: strings.qr.replaceTitle,
          body: strings.qr.replaceBody,
          confirmLabel: strings.qr.replaceConfirm,
        });
        if (!confirmed) return;
      } else {
        // "No QR label yet" can be a moment old while the screen re-reads on
        // focus: just back from linking a sticker, or one made on another
        // phone. Making one never asks, so it looks first rather than quietly
        // retire a sticker that is on the box (entities §15.2).
        const current = await repos.qr.getByContainer(id);
        if (current) {
          shown.wrote(current.token);
          binding.reload();
          toast.show({ message: strings.qr.alreadyLabelled });
          return;
        }
      }
      const made = await repos.qr.createAndBind(id);
      logEvent('qr_generated');
      invalidate();
      shown.wrote(made.token);
      haptics.success();
      if (action === 'replace') toast.show({ message: strings.qr.made });
    } catch (cause) {
      haptics.error();
      toast.show({ tone: 'error', message: labelFailureMessage(action, cause) });
    } finally {
      end();
    }
  }

  /** Unlinks the sticker; the container and everything in it stay as they are. */
  async function removeLabel() {
    if (!begin('remove')) return;
    try {
      const confirmed = await confirm({
        title: strings.qr.removeTitle,
        body: strings.qr.removeBody,
        confirmLabel: strings.qr.removeConfirm,
      });
      if (!confirmed) return;
      // `false` means it was already gone (another phone): the same end state.
      await repos.qr.unbind(id);
      logEvent('qr_unbound');
      invalidate();
      shown.wrote(null);
      haptics.success();
      toast.show({ message: strings.qr.removed });
    } catch (cause) {
      haptics.error();
      toast.show({ tone: 'error', message: labelFailureMessage('remove', cause) });
    } finally {
      end();
    }
  }

  /**
   * On iOS the label goes out as a picture, so the share sheet offers Save
   * Image and Print. Android's `Share` cannot attach a file, so it shares the
   * text and the link, as before; so does iOS if the picture fails.
   */
  async function shareLabel(container: { name: string | null; shortCode: string }, token: string) {
    if (!begin('share')) return;
    const payload = formatQrPayload(token);
    const text = shareText(container, payload, { withPayload: true });
    let picture: string | null = null;
    const svg = svgRef.current;
    if (Platform.OS === 'ios' && svg) {
      try {
        picture = await writeLabelPicture(svg, container.shortCode);
      } catch {
        // The text share below still works.
      }
    }
    // The share sheet covers the screen, so the guard is only needed while preparing.
    end();
    try {
      await Share.share(
        picture
          ? { url: picture, message: shareText(container, payload, { withPayload: false }) }
          : { message: text },
      );
      return;
    } catch {
      // A picture that will not share falls back to the text below.
    }
    if (picture) {
      try {
        await Share.share({ message: text });
        return;
      } catch {
        // Told below.
      }
    }
    toast.show({ tone: 'error', message: strings.qr.shareFailed });
  }

  const container = containerQuery.data;

  if (container === null) {
    if (containerQuery.cause) {
      return <ErrorState cause={containerQuery.cause} subject="container" onRetry={reloadAll} />;
    }
    if (containerQuery.loading) return <LoadingLabel />;
    return (
      <ErrorState
        cause={null}
        subject="container"
        secondary={{ label: strings.common.goToSpaces, onPress: () => goToTab('/spaces') }}
      />
    );
  }

  // Not knowing whether there is a label is said as such: offering "Make a
  // QR label" here could retire a sticker that is on the box.
  if (!shown.known && binding.data === null && binding.cause) {
    return <ErrorState cause={binding.cause} subject="container" onRetry={reloadAll} />;
  }
  if (!labelKnown) return <LoadingLabel />;

  // After its own write the screen shows what it wrote, not "what was loaded before".
  const refreshFailed =
    needsRefreshBanner(containerQuery.refreshFailed, containerQuery.cause) ||
    (!shown.known && needsRefreshBanner(binding.refreshFailed, binding.cause));
  const banner = refreshFailed ? (
    <Banner
      tone="info"
      message={strings.errors.refreshFailed}
      action={{ label: strings.common.tryAgain, onPress: reloadAll }}
    />
  ) : null;

  const token = shown.token;

  if (token === null) {
    return (
      <ScrollView contentContainerStyle={{ paddingBottom: space.xl + insets.bottom }}>
        {banner ? <View style={[styles.banner, styles.gutter]}>{banner}</View> : null}
        <EmptyState
          icon="qr"
          title={strings.qr.none.title}
          body={strings.qr.none.body}
          action={{
            label: strings.qr.make,
            icon: 'qr',
            // No confirm: the label has been read (and is looked up again), so
            // there is none to replace.
            onPress: () => void makeLabel('make'),
            loading: busy === 'make',
            testID: 'qr-generate',
          }}
          secondary={{
            label: strings.qr.link,
            icon: 'link',
            onPress: () => router.push(`/container/${id}/link`),
            testID: 'qr-link-sticker',
          }}
        />
      </ScrollView>
    );
  }

  return (
    <ScrollView
      contentContainerStyle={[styles.content, { paddingBottom: space.xl + insets.bottom }]}
    >
      {banner ? <View style={styles.banner}>{banner}</View> : null}
      <QrCard
        token={token}
        container={container}
        onSvg={(svg) => {
          svgRef.current = svg;
        }}
      />
      <AppText variant="meta" tone="graphite" center style={styles.hint}>
        {strings.qr.hint}
      </AppText>
      <Button
        label={strings.qr.share}
        icon="share"
        variant="secondary"
        loading={busy === 'share'}
        onPress={() => void shareLabel(container, token)}
        style={styles.share}
        testID="qr-share"
      />

      <Section title={strings.qr.problems}>
        <Sheet>
          <Row
            onPress={() => void makeLabel('replace')}
            disabled={busy !== null}
            aside={busy === 'replace' ? <Spinner /> : null}
            minHeight={OPTION_MIN}
            accessibilityLabel={strings.qr.replace}
            testID="qr-replace"
          >
            <AppText variant="name">{strings.qr.replace}</AppText>
          </Row>
          <SheetSeparator />
          <Row
            onPress={() => void removeLabel()}
            disabled={busy !== null}
            aside={busy === 'remove' ? <Spinner /> : null}
            minHeight={OPTION_MIN}
            accessibilityLabel={strings.qr.remove}
            testID="qr-remove"
          >
            <AppText variant="name" tone="signal">
              {strings.qr.remove}
            </AppText>
          </Row>
        </Sheet>
      </Section>
    </ScrollView>
  );
}

function Spinner() {
  const { colors } = useTheme();
  return <ActivityIndicator size="small" color={colors.graphite} />;
}

function LoadingLabel() {
  return (
    <View style={styles.loading}>
      <Skeleton variant="detail" />
    </View>
  );
}

const styles = StyleSheet.create({
  loading: {
    padding: GUTTER,
  },
  content: {
    paddingHorizontal: GUTTER,
    paddingTop: space.sm,
  },
  gutter: {
    marginHorizontal: GUTTER,
  },
  banner: {
    marginBottom: space.lg,
  },
  hint: {
    alignSelf: 'center',
    maxWidth: 420,
    marginTop: space.lg,
  },
  share: {
    alignSelf: 'center',
    marginTop: space.lg,
  },
});
