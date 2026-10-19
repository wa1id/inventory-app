/**
 * Generates the parity vectors for InventoryAppModels' shared seams from the real TypeScript:
 * src/ui/motion.ts (every duration, delay and easing, and motionMs), src/ui/haptics.ts (which
 * expo-haptics call each event makes) and the defaults src/ui/confirm.ts gives a confirm.
 *
 * Not part of the RN test suite. To regenerate (see native-ios/docs/CONVENTIONS.md):
 *
 *   ln -s /home/walid/inventory-app/node_modules node_modules   # once, in a worktree
 *   mkdir -p src/__vectors__/__tests__
 *   cp native-ios/Packages/InventoryKit/Tests/InventoryAppModelsTests/Fixtures/generator/shared-seams-vectors.test.ts \
 *      src/__vectors__/__tests__/
 *   npx jest src/__vectors__ --selectProjects logic
 *   rm -r src/__vectors__
 *
 * The JSON lands next to this folder, in Tests/InventoryAppModelsTests/Fixtures/shared-seams.json.
 */
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

const calls: unknown[][] = [];

// The logic project runs in plain Node: stand in for the native pieces these modules touch,
// recording what they are asked to do. Easing records its arguments so the curves serialise.
jest.mock('react-native', () => ({
  Platform: { OS: 'ios' },
  AccessibilityInfo: {
    isReduceMotionEnabled: () => Promise.resolve(false),
    addEventListener: () => ({ remove: () => undefined }),
  },
  Easing: {
    bezier: (...args: number[]) => ({ bezier: args }),
    out: (inner: unknown) => ({ out: inner }),
    cubic: 'cubic',
  },
  Keyboard: { scheduleLayoutAnimation: () => undefined },
  LayoutAnimation: { configureNext: () => undefined, create: () => ({}) },
  Alert: { alert: (...args: unknown[]) => calls.push(['Alert.alert', ...args]) },
  ActionSheetIOS: { showActionSheetWithOptions: () => undefined },
  Appearance: { getColorScheme: () => 'light' },
}));

jest.mock('expo-haptics', () => ({
  ...jest.requireActual('expo-haptics/src/Haptics.types'),
  selectionAsync: () => {
    calls.push(['selectionAsync']);
    return Promise.resolve();
  },
  impactAsync: (style: string) => {
    calls.push(['impactAsync', style]);
    return Promise.resolve();
  },
  notificationAsync: (type: string) => {
    calls.push(['notificationAsync', type]);
    return Promise.resolve();
  },
}));

// eslint-disable-next-line import/first
import { confirm } from '@/ui/confirm';
// eslint-disable-next-line import/first
import { haptics } from '@/ui/haptics';
// eslint-disable-next-line import/first
import { delay, duration, easing, motionMs } from '@/ui/motion';

const OUT = join(__dirname, '../../../native-ios/Packages/InventoryKit/Tests/InventoryAppModelsTests/Fixtures');

test('writes shared-seams.json', () => {
  const hapticCalls: Record<string, unknown[]> = {};
  for (const [name, play] of Object.entries(haptics)) {
    calls.length = 0;
    play();
    hapticCalls[name] = calls.slice();
  }

  const motionMsCases = [];
  for (const ms of Object.values(duration)) {
    for (const reduced of [false, true]) motionMsCases.push({ ms, reduced, result: motionMs(ms, reduced) });
  }

  calls.length = 0;
  void confirm({ title: 'Delete “Cordless drill”?', body: 'This cannot be undone.', confirmLabel: 'Delete' });
  void confirm({
    title: 'Discard?',
    body: 'Changes go.',
    confirmLabel: 'Discard',
    cancelLabel: 'Keep editing',
    destructive: false,
  });
  const confirms = calls.map(([, title, body, buttons, options]) => ({
    title,
    body,
    buttons: (buttons as { text: string; style: string }[]).map(({ text, style }) => ({ text, style })),
    cancelable: (options as { cancelable: boolean }).cancelable,
  }));

  writeFileSync(
    join(OUT, 'shared-seams.json'),
    `${JSON.stringify({ duration, delay, easing, motionMs: motionMsCases, haptics: hapticCalls, confirms }, null, 1)}\n`,
  );
});
