import { Tabs } from 'expo-router/js-tabs';

import { strings } from '@/i18n/strings';
import { DropZoneProvider } from '@/providers/DropZoneProvider';
import { LegacyTabRoot } from '@/ui/components/Screen';
import { TabBar } from '@/ui/components/TabBar';
import { useTheme } from '@/ui/theme';

/**
 * Home · Spaces · [Add] · Scan · Drop zone, on a custom bar (`TabBar`).
 *
 * Tab roots draw their own titles, so there is no tab header. Settings is
 * not a tab (issue #2): it is one button on Home. The drop zone's list is read
 * once here and shared by the tab badge, Home and the Drop zone screen.
 */
export default function TabsLayout() {
  const { colors } = useTheme();

  return (
    <DropZoneProvider>
      <Tabs
        tabBar={(props) => <TabBar {...props} />}
        screenLayout={({ children }) => <LegacyTabRoot>{children}</LegacyTabRoot>}
        screenOptions={{
          headerShown: false,
          sceneStyle: { backgroundColor: colors.plaster },
          lazy: true,
        }}
      >
        <Tabs.Screen name="index" options={{ title: strings.tabs.home }} />
        <Tabs.Screen name="spaces" options={{ title: strings.tabs.spaces }} />
        <Tabs.Screen name="scan" options={{ title: strings.tabs.scan }} />
        <Tabs.Screen name="drop-zone" options={{ title: strings.tabs.dropZone }} />
        {/* Hidden until Home's own search replaces it (S1). */}
        <Tabs.Screen name="search" options={{ href: null }} />
      </Tabs>
    </DropZoneProvider>
  );
}
