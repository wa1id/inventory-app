import { useMemo } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { spaceTint, withAlpha } from '@/ui/color';
import { Icon, type IconName } from '@/ui/components/Icon';
import { TYPE_ICON, useTheme } from '@/ui/theme';

type SpaceTileSize = 32 | 48 | 56 | 64;

const TILE: Record<SpaceTileSize, { radius: number; emoji: number }> = {
  32: { radius: 7, emoji: 17 },
  48: { radius: 9, emoji: 24 },
  56: { radius: 10, emoji: 28 },
  64: { radius: 12, emoji: 34 },
};

export interface SpaceTileProps {
  /** Whatever was stored: an emoji, several, letters, or nothing. */
  icon: string | null | undefined;
  color: string | null | undefined;
  size: SpaceTileSize;
  /** The surface the tile sits on, so dark-mode tints lean toward it. */
  surface?: 'sheet' | 'plaster';
}

/**
 * A space's icon on a 24 % tint of its colour.
 *
 * The tint is blended in JS against the surface rather than drawn translucent,
 * so ink beside it always has the contrast measured for it, whatever colour
 * was picked. The emoji is a fixed picture: system emoji font, no scaling
 * (the name beside it scales), clipped rather than reflowed when someone
 * stored several. Decorative; the name next to it is what is read.
 */
export function SpaceTile({ icon, color, size, surface = 'sheet' }: SpaceTileProps) {
  const { colors } = useTheme();
  const surfaceHex = colors[surface];
  const { fill, edge } = useMemo(
    () => ({ fill: spaceTint(color ?? '', surfaceHex), edge: withAlpha(color ?? '', 0.45) }),
    [color, surfaceHex],
  );
  const glyph = (icon ?? '').trim();
  const spec = TILE[size];

  return (
    <View
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={[
        styles.tile,
        {
          width: size,
          height: size,
          borderRadius: spec.radius,
          backgroundColor: fill,
          borderColor: edge,
        },
      ]}
    >
      {glyph ? (
        <Text
          allowFontScaling={false}
          numberOfLines={1}
          ellipsizeMode="clip"
          style={[
            styles.emoji,
            // Emoji ignore the colour; letters someone stored as an icon need ink.
            { color: colors.ink, fontSize: spec.emoji, lineHeight: Math.round(spec.emoji * 1.2) },
          ]}
        >
          {glyph}
        </Text>
      ) : (
        <Icon name="home" size={size / 2} color={colors.graphite} />
      )}
    </View>
  );
}

export interface TypeTileProps {
  /** A stored container type; unknown values draw the `other` tag. */
  type: string;
  size: 40 | 48 | 72;
  /** Draws another glyph in the same frame (the drop zone's tray in the place picker). */
  icon?: IconName;
}

/** A container type as a line icon in a small white square. Decorative. */
export function TypeTile({ type, size, icon }: TypeTileProps) {
  const { colors } = useTheme();
  const large = size === 72;

  return (
    <View
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={[
        styles.typeTile,
        {
          width: size,
          height: size,
          borderRadius: large ? 10 : 9,
          backgroundColor: colors.sheet,
          borderColor: colors.rule,
        },
      ]}
    >
      <Icon
        name={icon ?? TYPE_ICON[type] ?? 'other'}
        size={large ? 28 : 24}
        color={colors.graphite}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  tile: {
    borderWidth: 1,
    borderCurve: 'continuous',
    overflow: 'hidden',
    alignItems: 'center',
    justifyContent: 'center',
    flexShrink: 0,
  },
  emoji: {
    textAlign: 'center',
    includeFontPadding: false,
  },
  typeTile: {
    borderWidth: 1,
    borderCurve: 'continuous',
    alignItems: 'center',
    justifyContent: 'center',
    flexShrink: 0,
  },
});
