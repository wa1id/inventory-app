import { Tabs, useRouter } from 'expo-router';
import { Pressable, Text, type ColorValue } from 'react-native';

import { strings } from '@/i18n/strings';
import { MIN_TOUCH_TARGET, spacing, useTheme } from '@/ui/theme';

/** Emoji tab glyphs keep the MVP free of an icon-font dependency. */
function TabIcon({ glyph, color }: { glyph: string; color: ColorValue }) {
  return <Text style={{ fontSize: 20, color }}>{glyph}</Text>;
}

export default function TabsLayout() {
  const { colors } = useTheme();
  const router = useRouter();

  return (
    <Tabs
      screenOptions={{
        tabBarActiveTintColor: colors.primary,
        tabBarInactiveTintColor: colors.textMuted,
        tabBarStyle: { backgroundColor: colors.surface, borderTopColor: colors.border },
        headerStyle: { backgroundColor: colors.surface },
        headerTintColor: colors.text,
        sceneStyle: { backgroundColor: colors.background },
        // Settings sits outside the primary tabs (issue #2).
        headerRight: () => (
          <Pressable
            onPress={() => router.push('/settings')}
            accessibilityRole="button"
            accessibilityLabel={strings.common.settings}
            hitSlop={spacing.sm}
            style={{
              minWidth: MIN_TOUCH_TARGET,
              minHeight: MIN_TOUCH_TARGET,
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            <Text style={{ fontSize: 20 }}>⚙️</Text>
          </Pressable>
        ),
      }}
    >
      <Tabs.Screen
        name="index"
        options={{
          title: strings.tabs.spaces,
          tabBarIcon: ({ color }) => <TabIcon glyph="🏠" color={color} />,
        }}
      />
      <Tabs.Screen
        name="search"
        options={{
          title: strings.tabs.search,
          tabBarIcon: ({ color }) => <TabIcon glyph="🔎" color={color} />,
        }}
      />
      <Tabs.Screen
        name="scan"
        options={{
          title: strings.tabs.scan,
          tabBarIcon: ({ color }) => <TabIcon glyph="📷" color={color} />,
        }}
      />
    </Tabs>
  );
}
