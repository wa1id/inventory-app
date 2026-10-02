import { useEffect, useRef, useState } from 'react';
import { AccessibilityInfo, ActivityIndicator, Platform, StyleSheet, View } from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { useDelayedFlag } from '@/hooks/useDelayedFlag';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useToast } from '@/providers/ToastProvider';
import { logEvent } from '@/services/telemetry';
import { AppText } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { QrScanner } from '@/ui/components/QrScanner';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { confirm } from '@/ui/confirm';
import { labelOf, planSticker, type StickerPlan } from '@/ui/container/containerRules';
import { describeError } from '@/ui/errors';
import { haptics } from '@/ui/haptics';
import { delay } from '@/ui/motion';
import { goToTab } from '@/ui/navigation';
import { GUTTER, camera, radius, space } from '@/ui/theme';

type Phase =
  | { kind: 'scanning' }
  /** Looking the sticker up; the camera stays on, paused. */
  | { kind: 'checking' }
  /** A question is up; the camera is off until it is answered. */
  | { kind: 'deciding' }
  | { kind: 'linking' }
  | { kind: 'notOurs' }
  | { kind: 'failed'; cause: unknown };

interface PanelProps {
  tone: 'busy' | 'error';
  title?: string;
  message: string;
  action?: { label: string; onPress: () => void; testID: string };
}

/**
 * A notice over the bottom of the camera: white on the dark chip, so it reads
 * over any scene; errors get the coloured edge rather than coloured text
 * (signal on a chip over a bright scene is too faint).
 */
function Panel({ tone, title, message, action }: PanelProps) {
  const insets = useSafeAreaInsets();
  const announcement = title ? `${title}. ${message}` : message;

  // Android reads the live region; iOS needs telling.
  useEffect(() => {
    if (Platform.OS === 'ios') AccessibilityInfo.announceForAccessibility(announcement);
  }, [announcement]);

  return (
    <View
      accessibilityLiveRegion={tone === 'error' ? 'assertive' : 'polite'}
      style={[styles.panel, { bottom: insets.bottom + space.xl, backgroundColor: camera.chip }]}
    >
      {tone === 'error' ? (
        <View style={[styles.errorBar, { backgroundColor: camera.errorBar }]} />
      ) : null}
      <View style={styles.panelText}>
        {tone === 'busy' ? <ActivityIndicator color={camera.ink} /> : null}
        <View style={styles.panelWords}>
          {title ? (
            <AppText variant="heading" tone="camera">
              {title}
            </AppText>
          ) : null}
          <AppText variant="body" tone="camera">
            {message}
          </AppText>
        </View>
      </View>
      {action ? (
        <Button
          label={action.label}
          variant="secondary"
          onPress={action.onPress}
          testID={action.testID}
        />
      ) : null}
    </View>
  );
}

/**
 * Links a sticker printed earlier to this container: point the camera at it
 * and it is linked, with a question first only when something would stop
 * working.
 *
 * It replaces the old round trip through the Scan tab with a `bindTo` param,
 * which stacked a second tab shell; this is a camera over
 * the QR screen that closes back to it with a toast.
 */
export default function LinkStickerScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const toast = useToast();

  const containerQuery = useInventoryQuery(
    () => repos.containers.getWithCounts(id),
    `container:${id}`,
  );
  const container = containerQuery.data;
  const [phase, setPhase] = useState<Phase>({ kind: 'scanning' });
  const showChecking = useDelayedFlag(phase.kind === 'checking', delay.skeleton);

  const locked = id === DROP_ZONE_CONTAINER_ID;
  const active =
    !locked && container !== null && (phase.kind === 'scanning' || phase.kind === 'checking');

  // Closing (✕ or Android back) while a sticker is being read or linked must
  // not let the answer, arriving later, go back a second time and close the
  // QR screen underneath too.
  const openRef = useRef(true);
  useEffect(() => {
    openRef.current = true;
    return () => {
      openRef.current = false;
    };
  }, []);

  async function link(raw: string) {
    // The scanner only runs once the container is known.
    if (!container) return;
    setPhase({ kind: 'checking' });
    const label = labelOf(container);
    let plan: StickerPlan;
    try {
      plan = planSticker(await repos.qr.resolveScan(raw), container);
    } catch (cause) {
      if (openRef.current) {
        haptics.error();
        setPhase({ kind: 'failed', cause });
      }
      return;
    }
    // Closed while reading: nothing was written, so nothing to say.
    if (!openRef.current) return;

    if (plan.kind === 'invalid') {
      haptics.error();
      setPhase({ kind: 'notOurs' });
      return;
    }
    if (plan.kind === 'already') {
      haptics.success();
      router.back();
      toast.show({ message: strings.link.already(label) });
      return;
    }

    if (plan.confirm) {
      setPhase({ kind: 'deciding' });
      if (!(await confirm(plan.confirm)) || !openRef.current) {
        // Pointed at the wrong sticker, probably: carry on scanning.
        setPhase({ kind: 'scanning' });
        return;
      }
    }

    setPhase({ kind: 'linking' });
    try {
      await repos.qr.bind(plan.token, container.id);
    } catch (cause) {
      haptics.error();
      // The panel says it; with the camera already closed, a toast does.
      if (openRef.current) setPhase({ kind: 'failed', cause });
      else toast.show({ tone: 'error', message: strings.link.notLinked(label) });
      return;
    }
    logEvent('qr_bound');
    invalidate();
    haptics.success();
    // Linked even if the camera was closed meanwhile: still say so, but only
    // this screen closes.
    if (openRef.current) router.back();
    toast.show({ message: strings.link.linked(label) });
  }

  function scanAgain() {
    setPhase({ kind: 'scanning' });
  }

  let panel: PanelProps | null = null;
  if (locked) {
    panel = {
      tone: 'error',
      title: strings.errors.dropZoneLocked.title,
      message: strings.errors.dropZoneLocked.body,
      action: {
        label: strings.errors.dropZoneLocked.action,
        onPress: () => goToTab('/drop-zone'),
        testID: 'link-drop-zone',
      },
    };
  } else if (container === null && containerQuery.cause) {
    const described = describeError(containerQuery.cause, 'read', 'container');
    panel = {
      tone: 'error',
      title: described.title,
      message: described.body,
      action: {
        label: strings.common.tryAgain,
        onPress: containerQuery.reload,
        testID: 'link-try-again',
      },
    };
  } else if (container === null && !containerQuery.loading) {
    // Deleted, probably on another phone, while this was opening.
    panel = {
      tone: 'error',
      title: strings.errors.gone.container,
      message: strings.errors.gone.body,
      action: { label: strings.common.goBack, onPress: () => router.back(), testID: 'link-back' },
    };
  } else if (phase.kind === 'notOurs') {
    panel = {
      tone: 'error',
      title: strings.camera.notOurs.title,
      message: strings.camera.notOurs.body,
      action: { label: strings.camera.scanAgain, onPress: scanAgain, testID: 'link-scan-again' },
    };
  } else if (phase.kind === 'failed') {
    // Read wording for both steps: nothing was linked, and nothing was lost.
    const described = describeError(phase.cause, 'read', 'container');
    panel = {
      tone: 'error',
      title: described.title,
      message: described.body,
      action: { label: strings.common.tryAgain, onPress: scanAgain, testID: 'link-try-again' },
    };
  } else if (phase.kind === 'linking') {
    panel = { tone: 'busy', message: strings.link.linking };
  } else if (showChecking) {
    panel = { tone: 'busy', message: strings.link.checking };
  }

  return (
    <ScreenFrame kind="camera">
      <QrScanner
        active={active}
        title={container ? strings.link.title(labelOf(container)) : strings.link.titlePlain}
        onScan={link}
        onClose={() => router.back()}
        closeTestID="link-close"
      />
      {panel ? <Panel {...panel} /> : null}
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  panel: {
    position: 'absolute',
    left: GUTTER,
    right: GUTTER,
    gap: space.md,
    padding: space.lg,
    paddingStart: space.lg + 4,
    borderRadius: radius.card,
    borderCurve: 'continuous',
    alignItems: 'flex-start',
    overflow: 'hidden',
  },
  errorBar: {
    position: 'absolute',
    start: 0,
    top: 0,
    bottom: 0,
    width: 4,
  },
  panelText: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
  },
  panelWords: {
    flexShrink: 1,
    gap: space.xs,
  },
});
