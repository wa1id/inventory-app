import { useState } from 'react';
import { Platform, Pressable, StyleSheet, View } from 'react-native';
import { router } from 'expo-router';
import type { BottomTabBarProps } from 'expo-router/js-tabs';
import { CommonActions } from 'expo-router/react-navigation';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { useKeyboardInset } from '@/hooks/useKeyboardInset';
import { strings } from '@/i18n/strings';
import { useDropZone } from '@/providers/DropZoneProvider';
import { useBottomChrome } from '@/providers/ToastProvider';
import { AppText } from '@/ui/components/AppText';
import { Icon, type IconName } from '@/ui/components/Icon';
import { PressedOverlay, rippleFor } from '@/ui/components/PressFeedback';
import { Tape } from '@/ui/components/Tape';
import { haptics } from '@/ui/haptics';
import { MIN_TOUCH_TARGET, TAB_BAR_CONTENT, space, useTheme } from '@/ui/theme';

/** The bar's tabs by route name. Add is not a route; it sits between Spaces and Scan. */
const TABS: Record<string, { icon: IconName; label: string; testID: string }> = {
  index: { icon: 'home', label: strings.tabs.home, testID: 'tab-home' },
  spaces: { icon: 'spaces', label: strings.tabs.spaces, testID: 'tab-spaces' },
  scan: { icon: 'scan', label: strings.tabs.scan, testID: 'tab-scan' },
  'drop-zone': { icon: 'inbox', label: strings.tabs.dropZone, testID: 'tab-drop-zone' },
};

const ADD = 'add';
const SLOTS = ['index', 'spaces', ADD, 'scan', 'drop-zone'] as const;

/** The Add block's height; every slot's icon area matches it. */
const ADD_BLOCK_HEIGHT = 40;
/** On tablets the five slots stop growing and sit centred. */
const SLOT_MAX_WIDTH = 120;
const QUICK_SNAP_HREF = `/capture?containerId=${DROP_ZONE_CONTAINER_ID}&mode=fast` as const;

/**
 * Home · Spaces · [Add] · Scan · Drop zone.
 *
 * Add is an action, not a tab: an ink block in the middle, under either thumb,
 * and the only filled control in the bar. A press opens the Add sheet; a long
 * press goes straight to Quick Snap. The Drop zone tab carries a tape badge
 * with the number of items waiting: tape yellow, not red, because waiting is
 * not an alarm. Routes without a slot (the old Search tab) are not shown.
 */
export function TabBar({ state, navigation, insets }: BottomTabBarProps) {
  const { colors } = useTheme();
  const keyboard = useKeyboardInset();
  const dropZone = useDropZone();
  const [height, setHeight] = useState(0);
  // Android lifts the bar over the keyboard otherwise; iOS covers it.
  const hidden = Platform.OS === 'android' && keyboard.visible;
  useBottomChrome(hidden ? 0 : height);

  if (hidden) return null;

  const activeName = state.routes[state.index]?.name;
  const waiting = dropZone.loading ? 0 : dropZone.count;

  function press(name: string) {
    const route = state.routes.find((candidate) => candidate.name === name);
    if (!route) return;
    const event = navigation.emit({
      type: 'tabPress',
      target: route.key,
      canPreventDefault: true,
    });
    // A press on the active tab is the screen's own business (scroll to top,
    // focus search); it listens for `tabPress`.
    if (name !== activeName && !event.defaultPrevented) {
      navigation.dispatch({ ...CommonActions.navigate(route), target: state.key });
    }
  }

  return (
    <View
      accessibilityRole="tablist"
      onLayout={(event) => setHeight(Math.round(event.nativeEvent.layout.height))}
      style={[
        styles.bar,
        {
          backgroundColor: colors.sheet,
          borderTopColor: colors.rule,
          paddingBottom: Math.max(insets.bottom, space.sm),
        },
      ]}
    >
      <View style={styles.slots}>
        {SLOTS.map((name) => {
          if (name === ADD) return <AddSlot key={ADD} />;
          const tab = TABS[name];
          if (!tab || !state.routes.some((route) => route.name === name)) return null;
          const badge = name === 'drop-zone' && waiting > 0 ? waiting : 0;
          return (
            <TabSlot
              key={name}
              icon={tab.icon}
              label={tab.label}
              badge={badge}
              active={name === activeName}
              onPress={() => press(name)}
              testID={tab.testID}
            />
          );
        })}
      </View>
    </View>
  );
}

interface TabSlotProps {
  icon: IconName;
  label: string;
  /** Items waiting; 0 hides the badge. */
  badge: number;
  active: boolean;
  onPress: () => void;
  testID: string;
}

function TabSlot({ icon, label, badge, active, onPress, testID }: TabSlotProps) {
  const { colors } = useTheme();
  const tint = active ? colors.ink : colors.graphite;

  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="tab"
      accessibilityState={{ selected: active }}
      accessibilityLabel={badge > 0 ? `${label}, ${strings.tabs.waitingA11y(badge)}` : label}
      android_ripple={rippleFor(colors)}
      testID={testID}
      style={styles.slot}
    >
      {({ pressed }) => (
        <>
          <PressedOverlay pressed={pressed} />
          {active ? <View style={[styles.activeBar, { backgroundColor: colors.ink }]} /> : null}
          <View style={styles.iconBox}>
            <View>
              <Icon name={icon} size={24} color={tint} strokeWidth={active ? 2 : 1.75} />
              {badge > 0 ? (
                <View style={styles.badge}>
                  <Tape code={badge > 99 ? '99+' : String(badge)} size="badge" />
                </View>
              ) : null}
            </View>
          </View>
          <AppText
            variant="tab"
            numberOfLines={1}
            adjustsFontSizeToFit
            minimumFontScale={0.8}
            center
            style={{ color: tint }}
          >
            {label}
          </AppText>
        </>
      )}
    </Pressable>
  );
}

function AddSlot() {
  const { colors } = useTheme();

  function add() {
    haptics.tap();
    router.push('/item/new');
  }

  function quickSnap() {
    haptics.longPress();
    router.push(QUICK_SNAP_HREF);
  }

  return (
    <Pressable
      onPress={add}
      onLongPress={quickSnap}
      delayLongPress={350}
      accessibilityRole="button"
      accessibilityLabel={strings.tabs.addA11y}
      accessibilityHint={strings.tabs.addHint}
      accessibilityActions={[{ name: 'longpress', label: strings.tabs.quickSnapAction }]}
      onAccessibilityAction={(event) => {
        if (event.nativeEvent.actionName === 'longpress') quickSnap();
      }}
      testID="tab-add"
      style={styles.slot}
    >
      {({ pressed }) => (
        <>
          <View
            style={[styles.addBlock, { backgroundColor: pressed ? colors.inkPressed : colors.ink }]}
          >
            <Icon name="plus" size={24} color={colors.onInk} strokeWidth={2} />
          </View>
          <AppText variant="tab" numberOfLines={1} adjustsFontSizeToFit minimumFontScale={0.8}>
            {strings.tabs.add}
          </AppText>
        </>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  bar: {
    borderTopWidth: 1,
  },
  slots: {
    flexDirection: 'row',
    alignItems: 'stretch',
    alignSelf: 'center',
    width: '100%',
    maxWidth: SLOT_MAX_WIDTH * SLOTS.length,
    minHeight: TAB_BAR_CONTENT,
  },
  slot: {
    flex: 1,
    minHeight: MIN_TOUCH_TARGET,
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.xxs,
    paddingVertical: space.xs,
    paddingHorizontal: space.xxs,
  },
  activeBar: {
    position: 'absolute',
    top: 0,
    width: 24,
    height: 3,
    borderBottomLeftRadius: 2,
    borderBottomRightRadius: 2,
  },
  // As tall as the Add block, so all five labels sit on one line.
  iconBox: {
    height: ADD_BLOCK_HEIGHT,
    alignItems: 'center',
    justifyContent: 'center',
  },
  badge: {
    position: 'absolute',
    top: -4,
    end: -6,
  },
  addBlock: {
    width: 56,
    height: ADD_BLOCK_HEIGHT,
    borderRadius: 12,
    borderCurve: 'continuous',
    alignItems: 'center',
    justifyContent: 'center',
  },
});
