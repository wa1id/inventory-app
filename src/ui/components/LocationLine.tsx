import { Platform, Pressable, StyleSheet, View } from 'react-native';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { inlineIconSize, useLayoutScale } from '@/hooks/useLayoutScale';
import { strings } from '@/i18n/strings';
import type { PlaceLike } from '@/ui/a11y';
import { AppText, type TextTone } from '@/ui/components/AppText';
import { Icon } from '@/ui/components/Icon';
import { rippleFor } from '@/ui/components/PressFeedback';
import { SpacePip } from '@/ui/components/SpacePip';
import { Tape } from '@/ui/components/Tape';
import { openContainer, openSpace } from '@/ui/navigation';
import { MIN_TOUCH_TARGET, camera, useTheme } from '@/ui/theme';
import { TEXT_VARIANTS, maxScale, type TextVariant } from '@/ui/typography';

export type { PlaceLike } from '@/ui/a11y';

type LocationSize = 'row' | 'card' | 'inline';

const SIZES: Record<
  LocationSize,
  { variant: TextVariant; pip: 10 | 12 | 14; tape: boolean; inbox: number }
> = {
  row: { variant: 'where', pip: 12, tape: true, inbox: 20 },
  card: { variant: 'whereCard', pip: 14, tape: false, inbox: 24 },
  inline: { variant: 'meta', pip: 10, tape: true, inbox: 16 },
};

export interface LocationLineProps {
  place: PlaceLike;
  size: LocationSize;
  tone?: 'ink' | 'camera';
  /** False for a container's own row in search, where only its space is the answer. */
  showContainer?: boolean;
  /** `card` only: the space and the container names become links. */
  linked?: boolean;
}

function PlaceLink({
  label,
  variant,
  hint,
  testID,
  onPress,
}: {
  label: string;
  variant: TextVariant;
  hint: string;
  testID: string;
  onPress: () => void;
}) {
  const { colors } = useTheme();
  const { fontScale } = useLayoutScale();
  // The 48 pt target reaches past the text line rather than padding it, so a
  // wrapped path sets solid instead of opening a gap between its lines.
  const line =
    TEXT_VARIANTS[variant].lineHeight * Math.min(Math.max(fontScale, 1), maxScale(variant));
  const slop = Math.max(0, Math.ceil((MIN_TOUCH_TARGET - line) / 2));
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="link"
      accessibilityHint={hint}
      testID={testID}
      android_ripple={rippleFor(colors)}
      hitSlop={{ top: slop, bottom: slop, left: 4, right: 4 }}
      style={styles.link}
    >
      {({ pressed }) => (
        // Always underlined: touch has no hover to show that the name is a link.
        <AppText
          variant={variant}
          accessibilityRole="text"
          style={[
            styles.segment,
            styles.underline,
            Platform.OS === 'ios'
              ? { textDecorationColor: pressed ? colors.ink : colors.ruleStrong }
              : null,
          ]}
        >
          {label}
        </AppText>
      )}
    </Pressable>
  );
}

/**
 * The answer to "where is it?": pip, space › container, tape.
 *
 * The only way a location is drawn, so it always looks the same and is never
 * smaller than the name above it (`111b579`, issue #14). It never truncates:
 * each name wraps on its own and the tape moves to the next line whole. The
 * drop zone is always the tray and the words "Drop zone", never its stored
 * teal or its internal code. Not focusable on its own: the row around it
 * speaks it with `whereSpoken()`.
 */
export function LocationLine({
  place,
  size,
  tone = 'ink',
  showContainer = true,
  linked = false,
}: LocationLineProps) {
  const { colors } = useTheme();
  const { fontScale } = useLayoutScale();
  const spec = SIZES[size];
  const textTone: TextTone = tone === 'camera' ? 'camera' : 'ink';
  const quietTone: TextTone = tone === 'camera' ? 'camera' : 'graphite';
  const asLinks = linked && size === 'card';

  if (place.containerId === DROP_ZONE_CONTAINER_ID) {
    return (
      <View style={styles.line}>
        <Icon
          name="inbox"
          size={inlineIconSize(spec.inbox, fontScale)}
          color={tone === 'camera' ? camera.ink : colors.ink}
        />
        {/* One text, so a wrap falls between words rather than before the dot. */}
        <AppText variant={spec.variant} tone={textTone} style={styles.segment}>
          {strings.where.dropZone}
          {size === 'card' ? null : (
            <AppText variant={spec.variant} tone={quietTone}>
              {strings.where.notFiledYet}
            </AppText>
          )}
        </AppText>
      </View>
    );
  }

  const containerLabel = place.containerName ?? (spec.tape ? null : place.containerShortCode);

  return (
    <View style={styles.line}>
      <SpacePip color={place.spaceColor} size={spec.pip} />
      {asLinks ? (
        <PlaceLink
          label={place.spaceName}
          variant={spec.variant}
          hint={strings.a11y.opensSpace}
          testID="where-space"
          onPress={() => openSpace(place.spaceId)}
        />
      ) : (
        <AppText variant={spec.variant} tone={textTone} style={styles.segment}>
          {place.spaceName}
        </AppText>
      )}
      {showContainer ? (
        <>
          <AppText
            variant={spec.variant}
            tone={quietTone}
            accessibilityElementsHidden
            importantForAccessibility="no"
          >
            ›
          </AppText>
          {containerLabel !== null ? (
            asLinks ? (
              <PlaceLink
                label={containerLabel}
                variant={spec.variant}
                hint={strings.a11y.opensContainer}
                testID="where-container"
                onPress={() => openContainer(place.containerId)}
              />
            ) : (
              <AppText variant={spec.variant} tone={textTone} style={styles.segment}>
                {containerLabel}
              </AppText>
            )
          ) : null}
          {spec.tape ? <Tape code={place.containerShortCode} size="s" /> : null}
        </>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  line: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    columnGap: 6,
    rowGap: 2,
  },
  segment: {
    flexShrink: 1,
  },
  link: {
    justifyContent: 'center',
    flexShrink: 1,
  },
  underline: {
    textDecorationLine: 'underline',
  },
});
