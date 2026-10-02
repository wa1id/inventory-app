import { useEffect, useRef, useState } from 'react';
import { BackHandler, ScrollView, StyleSheet, View } from 'react-native';
import { SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';

import { strings } from '@/i18n/strings';
import { useHousehold } from '@/providers/HouseholdProvider';
import { useOnboarding } from '@/providers/OnboardingProvider';
import { logEvent } from '@/services/telemetry';
import { AppText } from '@/ui/components/AppText';
import { Button } from '@/ui/components/Button';
import { Icon, type IconName } from '@/ui/components/Icon';
import { Mark } from '@/ui/components/Mark';
import { JoinForm, type Joined } from '@/ui/household/JoinForm';
import { GUTTER, space, useTheme } from '@/ui/theme';

type Step = 'welcome' | 'join' | 'joined';

/** The three things the app is for, in the order she will need them. */
const FACT_ICONS: readonly IconName[] = ['search', 'plus', 'scan'];

/** Onboarding fits a phone; on an iPad it stays a readable column. */
const MAX_WIDTH = 480;

/**
 * The first screen on a new phone (issue #12: short, skippable, replayable
 * from Settings › How it works).
 *
 * Joining comes first, because the usual new phone is a second one joining
 * the household with the owner beside it (flow 6.8: "Join your household",
 * the code, "Join household", "Start"). Using the phone on its own is one tap
 * and asks nothing. It no longer promises suggestions a build may not have or
 * offline use a joined phone does not get (UX-16), and no longer sends a new
 * phone into creating its own first space on an empty local inventory.
 */
export default function OnboardingScreen() {
  const { colors } = useTheme();
  const insets = useSafeAreaInsets();
  const { complete } = useOnboarding();
  const { session } = useHousehold();
  const [step, setStep] = useState<Step>('welcome');
  const [householdName, setHouseholdName] = useState('');
  const finishing = useRef(false);

  async function finish(outcome: 'completed' | 'skipped', stepNumber: number) {
    if (finishing.current) return;
    finishing.current = true;
    // Status first, then storage (`OnboardingProvider`): the root stack's
    // guard flips to the tabs on this, so there is no navigation call here.
    await complete();
    logEvent('onboarding_finished', { outcome, step: stepNumber });
  }

  // Android back steps back from Join; on Welcome it leaves the app as usual,
  // and once joined there is nothing to go back to.
  useEffect(() => {
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
      if (step === 'join') {
        setStep('welcome');
        return true;
      }
      return step === 'joined';
    });
    return () => subscription.remove();
  }, [step]);

  function joined({ householdName: name }: Joined) {
    setHouseholdName(name);
    setStep('joined');
  }

  return (
    <SafeAreaView
      // The join form's bottom bar pads the home indicator itself.
      edges={step === 'join' ? ['top', 'left', 'right'] : ['top', 'left', 'right', 'bottom']}
      style={[styles.fill, { backgroundColor: colors.plaster }]}
    >
      <View style={styles.column}>
        {step === 'welcome' ? (
          <Welcome
            replaying={session !== null}
            onJoin={() => setStep('join')}
            onLocal={() => void finish('skipped', 0)}
            onContinue={() => void finish('completed', 0)}
          />
        ) : step === 'join' ? (
          <JoinForm
            onJoined={joined}
            // No header here: the form starts under the top safe-area inset,
            // which the keyboard avoidance has to know about or the
            // keyboard covers most of "Join household" on a notched phone.
            keyboardVerticalOffset={insets.top}
            header={
              <View style={styles.joinHead}>
                <Button
                  label={strings.onboarding.back}
                  onPress={() => setStep('welcome')}
                  icon="back"
                  variant="quiet"
                  size="sm"
                  testID="onboarding-back"
                  style={styles.back}
                />
                <AppText variant="title">{strings.household.joinHeading}</AppText>
                <AppText variant="body" tone="graphite">
                  {strings.household.joinBody}
                </AppText>
              </View>
            }
          />
        ) : (
          <JoinedStep
            householdName={householdName || (session?.householdName ?? '')}
            onStart={() => void finish('completed', 1)}
          />
        )}
      </View>
    </SafeAreaView>
  );
}

function Welcome({
  replaying,
  onJoin,
  onLocal,
  onContinue,
}: {
  /** Replayed from Settings on a phone that has already joined: nothing to choose. */
  replaying: boolean;
  onJoin: () => void;
  onLocal: () => void;
  onContinue: () => void;
}) {
  const { colors } = useTheme();
  const insets = useSafeAreaInsets();

  return (
    <>
      <ScrollView contentContainerStyle={styles.welcome}>
        <View style={styles.brand}>
          <Mark size={72} />
          <AppText variant="section" weight={800}>
            {strings.onboarding.brand}
          </AppText>
        </View>
        <AppText variant="display">{strings.onboarding.title}</AppText>
        <View style={styles.facts}>
          {strings.onboarding.facts.map((fact, index) => (
            <View key={fact} style={styles.fact}>
              <Icon name={FACT_ICONS[index] ?? 'info'} size={24} color={colors.ink} />
              <AppText variant="body" style={styles.flex}>
                {fact}
              </AppText>
            </View>
          ))}
        </View>
      </ScrollView>
      <View style={[styles.actions, { paddingBottom: Math.max(space.lg - insets.bottom, 0) }]}>
        {replaying ? (
          <Button
            label={strings.onboarding.continue}
            onPress={onContinue}
            fullWidth
            testID="onboarding-continue"
          />
        ) : (
          <>
            <Button
              label={strings.onboarding.join}
              onPress={onJoin}
              fullWidth
              testID="onboarding-join"
            />
            <Button
              label={strings.onboarding.local}
              onPress={onLocal}
              variant="quiet"
              fullWidth
              testID="onboarding-local"
            />
          </>
        )}
      </View>
    </>
  );
}

function JoinedStep({ householdName, onStart }: { householdName: string; onStart: () => void }) {
  const { colors } = useTheme();
  const insets = useSafeAreaInsets();

  return (
    <>
      <ScrollView contentContainerStyle={styles.joined}>
        <View style={[styles.check, { backgroundColor: colors.selected }]}>
          <Icon name="check" size={28} color={colors.ink} />
        </View>
        <AppText variant="title">{strings.onboarding.joinedTitle}</AppText>
        <AppText variant="body" tone="graphite">
          {strings.onboarding.joinedBody(householdName)}
        </AppText>
      </ScrollView>
      <View style={[styles.actions, { paddingBottom: Math.max(space.lg - insets.bottom, 0) }]}>
        <Button
          label={strings.onboarding.start}
          onPress={onStart}
          fullWidth
          testID="onboarding-start"
        />
      </View>
    </>
  );
}

const styles = StyleSheet.create({
  fill: {
    flex: 1,
  },
  flex: {
    flex: 1,
  },
  column: {
    flex: 1,
    width: '100%',
    maxWidth: MAX_WIDTH,
    alignSelf: 'center',
  },
  welcome: {
    flexGrow: 1,
    justifyContent: 'center',
    padding: GUTTER,
    paddingVertical: space.xxl,
    gap: space.xl,
  },
  brand: {
    gap: space.md,
  },
  facts: {
    gap: space.lg,
  },
  fact: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: space.md,
  },
  joinHead: {
    gap: space.sm,
  },
  // The chevron lines up with the title below rather than the button's padding.
  back: {
    marginStart: -space.md,
  },
  joined: {
    flexGrow: 1,
    justifyContent: 'center',
    padding: GUTTER,
    gap: space.md,
  },
  check: {
    width: 56,
    height: 56,
    borderRadius: 28,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: space.sm,
  },
  actions: {
    paddingHorizontal: GUTTER,
    paddingTop: space.md,
    gap: space.sm,
  },
});
