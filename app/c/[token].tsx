import { useEffect, useRef, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useToast } from '@/providers/ToastProvider';
import type { ScanOutcome } from '@/repositories/qr';
import { rememberPlace } from '@/services/places/recentPlaces';
import { logError, logEvent } from '@/services/telemetry';
import { AppText } from '@/ui/components/AppText';
import { EmptyState } from '@/ui/components/EmptyState';
import { ErrorState } from '@/ui/components/ErrorState';
import { PlacePicker, type PickedPlace } from '@/ui/components/PlacePicker';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { Skeleton } from '@/ui/components/Skeleton';
import { confirm } from '@/ui/confirm';
import { describeError } from '@/ui/errors';
import { haptics } from '@/ui/haptics';
import { goToTab } from '@/ui/navigation';
import { labelFor, linkFailureMessage, planBind, tokenParam } from '@/ui/scan/scanRules';
import { GUTTER, space } from '@/ui/theme';

/** The answer for one lookup, tagged with the request it belongs to. */
type Resolution = { request: string } & ({ outcome: ScanOutcome } | { cause: unknown });

/**
 * A QR label, opened from the iPhone Camera (`inventory://c/<token>`) or
 * handed over by the Scan tab.
 *
 * QR payloads carry a URL so the *system* camera can open the app too. The
 * token resolves through the same repository the scanner uses: a linked
 * label replaces this screen with its container (the root layout's anchor
 * puts Home underneath on a cold start). A label this app made but never
 * linked is linked here, to a container picked from the grouped list, so the
 * token is never lost and she is not sent back to rescan it. A
 * failed lookup offers "Try again" instead of "Opening…" for ever.
 *
 * The lookup is a one-shot read that ends in navigation, so it is not a
 * `useInventoryQuery`: re-reading on focus or after the link is written would
 * replace the screen a second time.
 */
export default function QrLabelScreen() {
  const params = useLocalSearchParams<{ token: string }>();
  const token = tokenParam(params.token);
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const toast = useToast();

  const [attempt, setAttempt] = useState(0);
  const [resolution, setResolution] = useState<Resolution | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const bindingRef = useRef(false);

  // Back (the header, the iOS swipe or Android back) still works while a
  // label is being linked over a slow connection. The answer, arriving after
  // that, must not `replace` whatever screen is in front by then (it would
  // swap out the tab shell itself), so it checks this first; the container's
  // link screen (`app/container/[id]/link.tsx`) does the same.
  const openRef = useRef(true);
  useEffect(() => {
    openRef.current = true;
    return () => {
      openRef.current = false;
    };
  }, []);

  // "Resolving" is derived: no answer yet for this token and this attempt.
  const request = `${token}|${attempt}`;
  const current = resolution?.request === request ? resolution : null;

  // The latest lookup, so the effect below re-runs for a new request only and
  // never because the repositories object was rebuilt. Effects run
  // in order, so the lookup effect always sees this render's closure.
  const resolveRef = useRef(() => repos.qr.resolveScan(token));
  useEffect(() => {
    resolveRef.current = () => repos.qr.resolveScan(token);
  });

  useEffect(() => {
    let cancelled = false;

    resolveRef.current().then(
      (outcome) => {
        if (cancelled) return;
        logEvent('qr_deeplink', { outcome: outcome.kind });
        setResolution({ request, outcome });
        if (outcome.kind !== 'bound') return;
        // The drop zone is a tab, never a container screen.
        if (outcome.container.id === DROP_ZONE_CONTAINER_ID) goToTab('/drop-zone');
        else router.replace(`/container/${outcome.container.id}`);
      },
      (cause: unknown) => {
        if (cancelled) return;
        logError('qr_deeplink_failed', { errorClass: describeError(cause).kind });
        setResolution({ request, cause });
      },
    );

    return () => {
      cancelled = true;
    };
  }, [request]);

  async function link(place: PickedPlace, labelToken: string) {
    // Bind mode never offers the drop zone; the ref stops a second tap before
    // the list has locked itself.
    if (place.kind !== 'container' || bindingRef.current) return;
    bindingRef.current = true;
    const { option } = place;
    const label = labelFor(option);
    setBusyId(option.id);

    try {
      // The picker's list carries no label token, so ask for this container's
      // own label before deciding whether to warn.
      const plan = planBind(await repos.qr.getByContainer(option.id), labelToken, label);
      // Left before anything was written: they changed their mind, so nothing happens.
      if (!openRef.current) return;
      if (plan.confirm && !(await confirm(plan.confirm))) {
        bindingRef.current = false;
        setBusyId(null);
        return;
      }
      if (plan.write) {
        await repos.qr.bind(labelToken, option.id);
        logEvent('qr_bound');
        invalidate();
      }
      void rememberPlace(option.id);
      haptics.success();
      // Linked even if they left meanwhile: still say so, but open nothing.
      if (openRef.current) router.replace(`/container/${option.id}`);
      toast.show({ message: strings.deepLink.linked(label) });
    } catch (cause) {
      // Nothing was linked; the label and the list stay, so trying again is one tap.
      bindingRef.current = false;
      setBusyId(null);
      logError('qr_bind_failed', { errorClass: describeError(cause, 'label', 'container').kind });
      haptics.error();
      toast.show({ tone: 'error', message: linkFailureMessage(cause) });
    }
  }

  if (current && 'cause' in current) {
    return (
      <ScreenFrame kind="detail">
        <ErrorState cause={current.cause} onRetry={() => setAttempt((value) => value + 1)} />
      </ScreenFrame>
    );
  }

  // A linked label shows the same shape until the container replaces this screen.
  if (!current || current.outcome.kind === 'bound') {
    return (
      <ScreenFrame kind="detail">
        <View style={styles.loading}>
          <Skeleton variant="detail" label={strings.deepLink.opening} />
        </View>
      </ScreenFrame>
    );
  }

  if (current.outcome.kind === 'invalid') {
    return (
      <ScreenFrame kind="detail">
        <EmptyState
          icon="qr"
          title={strings.scan.invalidTitle}
          body={strings.scan.invalidBody}
          action={{ label: strings.common.goToHome, onPress: () => goToTab('/') }}
        />
      </ScreenFrame>
    );
  }

  const labelToken = current.outcome.token;
  return (
    <ScreenFrame kind="detail">
      <View style={styles.head}>
        <AppText variant="heading">{strings.deepLink.newTitle}</AppText>
        <AppText variant="body" tone="graphite">
          {strings.deepLink.newBody}
        </AppText>
      </View>
      <PlacePicker mode="bind" busyId={busyId} onPick={(place) => link(place, labelToken)} />
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  loading: {
    paddingTop: space.lg,
    paddingHorizontal: GUTTER,
  },
  head: {
    gap: space.xs,
    paddingTop: space.lg,
    paddingHorizontal: GUTTER,
    paddingBottom: space.xs,
  },
});
