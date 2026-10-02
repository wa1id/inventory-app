import type { ReactNode } from 'react';
import { StyleSheet, View } from 'react-native';
import { SafeAreaView, type Edge } from 'react-native-safe-area-context';

import { AppText } from '@/ui/components/AppText';
import { ConnectionBanner } from '@/ui/components/ConnectionBanner';
import { CONTENT_MAX_WIDTH, GUTTER, camera, space, useTheme } from '@/ui/theme';

export type ScreenKind = 'tabRoot' | 'detail' | 'modal' | 'camera';

/**
 * Safe-area edges per kind of screen:
 * - tab roots have no native header, so they pad the top themselves; the tab
 *   bar pads the bottom;
 * - pushed screens and sheets sit under a native header; their bottom is
 *   padded by the bottom bar, or by the list's own content padding;
 * - camera chrome positions itself over the full-bleed picture.
 */
export const FRAME_EDGES: Record<ScreenKind, Edge[]> = {
  tabRoot: ['top', 'left', 'right'],
  detail: ['left', 'right'],
  modal: ['left', 'right'],
  camera: [],
};

export interface ScreenFrameProps {
  kind: ScreenKind;
  children?: ReactNode;
  /** Pinned under the content; usually a `BottomBar`. */
  bottomBar?: ReactNode;
  /** The connection banner at the top. On by default, except on camera screens. */
  banner?: boolean;
  testID?: string;
}

/**
 * The frame of every screen: the plaster wall, the safe area, the connection
 * banner above the content (never inside a scroll view, so it cannot scroll
 * away) and the bottom bar slot. Content is centred at 640 pt on iPad.
 */
export function ScreenFrame({
  kind,
  children,
  bottomBar,
  banner = kind !== 'camera',
  testID,
}: ScreenFrameProps) {
  const { colors } = useTheme();

  return (
    <SafeAreaView
      testID={testID}
      edges={FRAME_EDGES[kind]}
      style={[styles.frame, { backgroundColor: kind === 'camera' ? camera.bg : colors.plaster }]}
    >
      {banner ? <ConnectionBanner /> : null}
      <View style={kind === 'camera' ? styles.fill : styles.content}>{children}</View>
      {bottomBar}
    </SafeAreaView>
  );
}

export interface TabRootHeaderProps {
  title: string;
  subtitle?: ReactNode;
  /** `IconButton`s or small buttons, at the end of the title row. */
  actions?: ReactNode;
}

/**
 * The big title of a tab root (Home, Spaces, Drop zone). It sits in the
 * content and scrolls away with it; there is no native header on tab roots.
 */
export function TabRootHeader({ title, subtitle, actions }: TabRootHeaderProps) {
  return (
    <View style={styles.header}>
      <View style={styles.titleRow}>
        <AppText variant="display" style={styles.title}>
          {title}
        </AppText>
        {actions ? <View style={styles.actions}>{actions}</View> : null}
      </View>
      {subtitle ? <View style={styles.subtitle}>{subtitle}</View> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  frame: {
    flex: 1,
  },
  fill: {
    flex: 1,
  },
  content: {
    flex: 1,
    width: '100%',
    maxWidth: CONTENT_MAX_WIDTH,
    alignSelf: 'center',
  },
  header: {
    paddingTop: space.md,
    paddingHorizontal: GUTTER,
    paddingBottom: space.lg,
  },
  titleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
  },
  title: {
    flex: 1,
  },
  actions: {
    flexDirection: 'row',
    alignItems: 'center',
    // The 48 pt targets' padding lines the last glyph up with the gutter.
    marginEnd: -space.md,
  },
  subtitle: {
    marginTop: space.xs,
    gap: space.xxs,
  },
});
