import { useEffect, useRef, useState } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import { useNavigation, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useInventoryQuery, type QueryResult } from '@/hooks/useInventoryQuery';
import { useNow } from '@/hooks/useNow';
import { strings } from '@/i18n/strings';
import { useConnection } from '@/providers/ConnectionProvider';
import { useDatabase } from '@/providers/DatabaseProvider';
import { useHousehold } from '@/providers/HouseholdProvider';
import { useToast } from '@/providers/ToastProvider';
import { HouseholdHttpError, type HouseholdSession } from '@/services/household/client';
import { listDevices, revokeDevice, type HouseholdDevice } from '@/services/household/devices';
import { importLocalInventory } from '@/services/household/importHousehold';
import {
  clearImportOffer,
  readImportOffer,
  type ImportOffer,
} from '@/services/household/importOffer';
import { logError, logEvent } from '@/services/telemetry';
import { AppText } from '@/ui/components/AppText';
import { Banner } from '@/ui/components/Banner';
import { Button } from '@/ui/components/Button';
import { Icon } from '@/ui/components/Icon';
import { Row } from '@/ui/components/Row';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { Section, Sheet, SheetSeparator } from '@/ui/components/Sheet';
import { Skeleton } from '@/ui/components/Skeleton';
import { confirm } from '@/ui/confirm';
import { describeError, type ErrorContext } from '@/ui/errors';
import { haptics } from '@/ui/haptics';
import { JoinForm, type Joined } from '@/ui/household/JoinForm';
import { deviceMeta, sortDevices } from '@/ui/household/status';
import { goToTab } from '@/ui/navigation';
import { usePullToRefresh } from '@/ui/spaces/usePullToRefresh';
import { GUTTER, OPTION_MIN, space, useTheme } from '@/ui/theme';

/** Leaving tells the home server only in passing; the request must not linger on a dead connection. */
const LEAVE_TIMEOUT_MS = 5_000;

/**
 * Settings › Household: join the household, or, once joined, see this phone,
 * the other phones (and remove one), copy this phone's own inventory in, and
 * leave. Reached from Settings, Home's unpaired notice and the removed-phone
 * layer's "Join again".
 */
export default function HouseholdScreen() {
  const { session } = useHousehold();
  return session ? <Paired session={session} /> : <Unpaired />;
}

/**
 * Back to wherever Household was opened from; Home if it was somehow the only
 * screen. Nothing if the person already left (a slow join or leave finishing
 * late), which would otherwise pop the screen they went back to.
 */
function leaveScreen(
  router: ReturnType<typeof useRouter>,
  navigation: { isFocused: () => boolean },
) {
  if (!navigation.isFocused()) return;
  if (router.canGoBack()) router.back();
  else goToTab('/');
}

function Unpaired() {
  const router = useRouter();
  // The route's own navigation object: still answers after joining swaps this
  // view for the paired one, and reads the live stack.
  const navigation = useNavigation();
  const toast = useToast();

  function joined({ householdName, hasImportOffer }: Joined) {
    toast.show({ message: strings.household.joined(householdName) });
    // A phone with an inventory of its own stays here: the paired view now
    // offers to copy it in, and that is best done before anything changes.
    // Her phone (empty at join time) goes straight back.
    if (!hasImportOffer) leaveScreen(router, navigation);
  }

  return (
    <ScreenFrame kind="detail">
      <JoinForm
        onJoined={joined}
        header={
          <View style={styles.intro}>
            <AppText variant="heading">{strings.household.joinHeading}</AppText>
            <AppText variant="body" tone="graphite">
              {strings.household.joinBody}
            </AppText>
          </View>
        }
      />
    </ScreenFrame>
  );
}

function Paired({ session }: { session: HouseholdSession }) {
  const router = useRouter();
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();
  const toast = useToast();
  const { state: database, invalidate } = useDatabase();
  const { disconnect } = useHousehold();

  const devices = useInventoryQuery(() => listDevices(session), `devices:${session.deviceId}`);
  const refreshControl = usePullToRefresh(devices.loading, devices.reload);

  const [offer, setOffer] = useState<ImportOffer | null>(null);
  useEffect(() => {
    let cancelled = false;
    void readImportOffer().then((stored) => {
      if (!cancelled) setOffer(stored);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const [importing, setImporting] = useState(false);
  const [importFailure, setImportFailure] = useState<{ cause: unknown } | null>(null);
  const [removingId, setRemovingId] = useState<string | null>(null);
  const [removeFailure, setRemoveFailure] = useState<{ cause: unknown; name: string } | null>(null);
  const [leaving, setLeaving] = useState(false);
  // Confirms are async; a second tap while one is open must not start a second write.
  const busyRef = useRef(false);

  async function copyIn() {
    if (busyRef.current || database.status !== 'ready') return;
    busyRef.current = true;
    const ok = await confirm({
      title: strings.household.importConfirmTitle,
      body: strings.household.importConfirmBody,
      confirmLabel: strings.household.importConfirm,
      destructive: false,
    });
    if (!ok) {
      busyRef.current = false;
      return;
    }
    setImporting(true);
    setImportFailure(null);
    try {
      // From the local database, never the shadowed repositories: what this
      // phone held of its own. The import itself is unchanged.
      const result = await importLocalInventory({ session, db: database.repos.db });
      await clearImportOffer();
      setOffer(null);
      invalidate();
      haptics.success();
      toast.show({ message: strings.household.copied(result.items, result.photosUploaded) });
    } catch (cause) {
      // Never the raw message (codes like `http_500`).
      logError('household_import_failed', {
        errorClass: cause instanceof Error ? cause.name : 'unknown',
      });
      setImportFailure({ cause });
      haptics.error();
    } finally {
      busyRef.current = false;
      setImporting(false);
    }
  }

  async function notNeeded() {
    await clearImportOffer();
    setOffer(null);
  }

  async function remove(device: HouseholdDevice) {
    if (busyRef.current) return;
    busyRef.current = true;
    const ok = await confirm({
      title: strings.household.removeTitle(device.name),
      body: strings.household.removeBody,
      confirmLabel: strings.household.removeConfirm,
    });
    if (!ok) {
      busyRef.current = false;
      return;
    }
    setRemovingId(device.id);
    setRemoveFailure(null);
    try {
      await revokeDevice(session, device.id);
      logEvent('device_removed');
      devices.reload();
      toast.show({ message: strings.household.removed(device.name) });
    } catch (cause) {
      logError('household_remove_failed', {
        statusCode: cause instanceof HouseholdHttpError ? cause.status : null,
        errorClass: cause instanceof Error ? cause.name : 'unknown',
      });
      setRemoveFailure({ cause, name: device.name });
      haptics.error();
    } finally {
      busyRef.current = false;
      setRemovingId(null);
    }
  }

  async function leave() {
    if (busyRef.current) return;
    busyRef.current = true;
    const ok = await confirm({
      title: strings.household.leaveTitle,
      body: strings.household.leaveBody,
      confirmLabel: strings.household.leaveConfirm,
    });
    if (!ok) {
      busyRef.current = false;
      return;
    }
    setLeaving(true);
    // Forget the session first. Once the home server drops this phone's
    // token, any request still in flight would come back 401 and flash the
    // removed-phone layer over a phone that is leaving on purpose.
    await disconnect();
    // Then tell the home server, best effort and not waited for, so the
    // household's list of phones stays tidy and leaving is instant offline:
    // leaving itself only forgets the session here.
    void revokeDevice(session, session.deviceId, { timeoutMs: LEAVE_TIMEOUT_MS }).catch(
      () => undefined,
    );
    await clearImportOffer();
    logEvent('household_left');
    invalidate();
    leaveScreen(router, navigation);
    toast.show({ message: strings.household.left });
  }

  return (
    <ScreenFrame kind="detail">
      <ScrollView
        contentContainerStyle={[styles.content, { paddingBottom: insets.bottom + space.xl }]}
        // The hook returns a bare `RefreshControl` element on purpose: Android
        // passes it the content as children, which a wrapper would drop.
        refreshControl={refreshControl}
      >
        <StatusCard session={session} />

        {offer ? (
          <View style={styles.offer}>
            {/* The choices sit in the notice they answer, as on Home's unpaired notice. */}
            <Banner
              tone="info"
              message={strings.household.importNotice(offer.spaces, offer.items)}
              action={{
                // Busy keeps the label, as every button does, and adds a spinner.
                label: strings.household.importAction,
                onPress: () => void copyIn(),
                loading: importing,
                testID: 'household-import',
              }}
              secondary={
                importing
                  ? undefined
                  : { label: strings.household.notNeeded, onPress: () => void notNeeded() }
              }
            />
            {importFailure ? (
              // Read wording on purpose: nothing was typed to keep, and copying
              // again is safe ("…then try again. Nothing on this phone was lost.").
              <FailureNotice cause={importFailure.cause} context="read" />
            ) : null}
          </View>
        ) : null}

        <Section title={strings.household.phones}>
          <View style={styles.phones}>
            {removeFailure ? (
              <FailureNotice
                cause={removeFailure.cause}
                context="delete"
                offlineMessage={strings.household.removeOffline(removeFailure.name)}
                onDismiss={() => setRemoveFailure(null)}
              />
            ) : null}
            <Phones
              query={devices}
              thisDeviceId={session.deviceId}
              removingId={removingId}
              onRemove={(device) => void remove(device)}
            />
          </View>
        </Section>

        <View style={styles.leave}>
          <Button
            label={strings.household.leave}
            onPress={() => void leave()}
            loading={leaving}
            variant="destructive"
            flush
            testID="household-leave"
          />
        </View>
      </ScrollView>
    </ScreenFrame>
  );
}

/** "This phone is “Kitchen iPhone”", the household's name and whether the home server answers. */
function StatusCard({ session }: { session: HouseholdSession }) {
  const { colors } = useTheme();
  const { state } = useConnection();
  // Only a confirmed answer reads as connected; a failing request is said at once here.
  const connected = state === 'online';

  return (
    <Sheet inset>
      <View style={styles.statusHead}>
        <Icon name="phone" size={24} color={colors.ink} />
        <AppText variant="heading" style={styles.flex}>
          {strings.household.thisPhoneIs(session.deviceName)}
        </AppText>
      </View>
      <View style={styles.statusBody}>
        <AppText variant="meta" tone="graphite">
          {strings.household.partOf(session.householdName)}
        </AppText>
        {/* One stop for the dot and its word, but not a live region: every
            `unsure` blip would be read aloud, and the connection banner
            already says a real outage. */}
        <View style={styles.statusLine} accessible>
          <View style={[styles.dot, { backgroundColor: connected ? colors.ink : colors.signal }]} />
          <AppText variant="meta" tone={connected ? 'ink' : 'signal'} weight={600}>
            {connected ? strings.connection.connected : strings.connection.reconnectingShort}
          </AppText>
        </View>
      </View>
    </Sheet>
  );
}

/** A write that did not happen, in plain words; the rest of the screen keeps working. */
function FailureNotice({
  cause,
  context,
  offlineMessage,
  onDismiss,
}: {
  cause: unknown;
  context: ErrorContext;
  /**
   * Replaces the shared offline sentence, whose "What you typed is still
   * here" fits a form, not removing a phone.
   */
  offlineMessage?: string;
  onDismiss?: () => void;
}) {
  const described = describeError(cause, context);
  return (
    <Banner
      tone="warning"
      title={described.title}
      message={described.kind === 'offline' && offlineMessage ? offlineMessage : described.body}
      onDismiss={onDismiss}
      live="assertive"
    />
  );
}

interface PhonesProps {
  query: QueryResult<HouseholdDevice[]>;
  thisDeviceId: string;
  removingId: string | null;
  onRemove: (device: HouseholdDevice) => void;
}

/**
 * Every phone in the household (K19, #47). Any phone may remove any other;
 * this phone leaves with "Leave the household…" instead. A failed read is an
 * inline notice, so joining status, the import offer and Leave still work.
 */
function Phones({ query, thisDeviceId, removingId, onRemove }: PhonesProps) {
  const now = useNow(60_000);
  const { state: connection } = useConnection();
  const { data, loading, cause, refreshFailed, reload } = query;

  if (data === null) {
    if (cause) {
      const described = describeError(cause, 'read');
      if (described.kind === 'offline' && connection !== 'online') {
        // The connection banner already says the home server is out of reach,
        // and its "Try again" reloads this list; a second warning here made a
        // secondary list the loudest thing on the screen.
        return (
          <AppText variant="meta" tone="graphite">
            {strings.household.phonesOffline}
          </AppText>
        );
      }
      return (
        <Banner
          tone="warning"
          title={described.title}
          message={described.body}
          action={{ label: strings.common.tryAgain, onPress: reload }}
        />
      );
    }
    return loading ? <Skeleton variant="rows" rows={2} thumb={null} /> : null;
  }

  const showRefreshFailed = refreshFailed && describeError(cause, 'read').kind !== 'offline';

  return (
    <>
      {showRefreshFailed ? (
        <Banner
          tone="info"
          message={strings.errors.refreshFailed}
          action={{ label: strings.common.tryAgain, onPress: reload }}
        />
      ) : null}
      <Sheet>
        {sortDevices(data, thisDeviceId).map((device, index) => {
          const meta = deviceMeta(device, thisDeviceId, now);
          const mine = device.id === thisDeviceId;
          return (
            <View key={device.id}>
              {index > 0 ? <SheetSeparator /> : null}
              <PhoneRow
                device={device}
                meta={meta}
                removable={!mine}
                removing={removingId === device.id}
                onRemove={() => onRemove(device)}
              />
            </View>
          );
        })}
      </Sheet>
    </>
  );
}

function PhoneRow({
  device,
  meta,
  removable,
  removing,
  onRemove,
}: {
  device: HouseholdDevice;
  meta: string;
  removable: boolean;
  removing: boolean;
  onRemove: () => void;
}) {
  const { colors } = useTheme();
  return (
    <Row
      leading={<Icon name="phone" size={24} color={colors.graphite} />}
      minHeight={OPTION_MIN}
      accessibilityLabel={strings.household.phoneA11y(device.name, meta)}
      tool={
        removable ? (
          <Button
            label={strings.household.remove}
            accessibilityLabel={strings.household.removeA11y(device.name)}
            onPress={onRemove}
            loading={removing}
            variant="destructive"
            size="sm"
            testID={`device-remove-${device.id}`}
          />
        ) : null
      }
    >
      <AppText variant="name">{device.name}</AppText>
      <AppText variant="meta" tone="graphite">
        {meta}
      </AppText>
    </Row>
  );
}

const styles = StyleSheet.create({
  intro: {
    gap: space.sm,
  },
  content: {
    padding: GUTTER,
  },
  flex: {
    flex: 1,
  },
  statusHead: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
  },
  statusBody: {
    marginTop: space.sm,
    paddingStart: 24 + space.md,
    gap: space.xs,
  },
  statusLine: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
  },
  dot: {
    width: 8,
    height: 8,
    borderRadius: 4,
  },
  offer: {
    marginTop: space.xl,
    gap: space.sm,
  },
  phones: {
    gap: space.sm,
  },
  leave: {
    marginTop: space.xxxl,
  },
});
