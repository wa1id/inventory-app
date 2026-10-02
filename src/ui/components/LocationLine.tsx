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
import type { TextVariant } from '@/ui/typography';

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
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="link"
      accessibilityHint={hint}
      testID={testID}
      android_ripple={rippleFor(colors)}
      hitSlop={4}
      style={styles.link}
    >
      {({ pressed }) => (
        <AppText
          variant={variant}
          accessibilityRole="text"
          style={[styles.segment, pressed && Platform.OS === 'ios' ? styles.underline : null]}
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
        <AppText variant={spec.variant} tone={textTone} style={styles.segment}>
          {strings.where.dropZone}
        </AppText>
        {size === 'card' ? null : (
          <AppText variant={spec.variant} tone={quietTone} style={styles.segment}>
            {strings.where.notFiledYet}
          </AppText>
        )}
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
    minHeight: MIN_TOUCH_TARGET,
    justifyContent: 'center',
    flexShrink: 1,
  },
  underline: {
    textDecorationLine: 'underline',
  },
});
