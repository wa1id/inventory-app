import { StyleSheet, View, type DimensionValue } from 'react-native';

import { useDelayedFlag } from '@/hooks/useDelayedFlag';
import { strings } from '@/i18n/strings';
import { Sheet, SheetSeparator } from '@/ui/components/Sheet';
import { delay } from '@/ui/motion';
import {
  OPTION_MIN,
  ROW_GAP,
  ROW_MIN,
  ROW_MIN_PHOTO,
  ROW_PADDING,
  THUMB_DETAIL,
  radius,
  space,
  useTheme,
} from '@/ui/theme';

export interface SkeletonProps {
  variant: 'list' | 'rows' | 'detail' | 'options' | 'grid';
  rows?: number;
  thumb?: 56 | 76 | null;
  /** What the hidden progress label says ("Opening that label…"); "Loading…" by default. */
  label?: string;
}

function Block({
  width,
  height,
  round,
}: {
  width: DimensionValue;
  height: number;
  round?: number;
}) {
  const { colors } = useTheme();
  return (
    <View
      style={{
        width,
        height,
        borderRadius: round ?? 4,
        backgroundColor: colors.sheet2,
      }}
    />
  );
}

/** An empty frame where a card or a stepper will be. */
function Outline({ height, round }: { height: number; round: number }) {
  const { colors } = useTheme();
  return (
    <View style={[styles.outline, { height, borderRadius: round, borderColor: colors.sheet2 }]} />
  );
}

function SkeletonRows({
  count,
  thumb,
  minHeight,
}: {
  count: number;
  thumb: number | null;
  minHeight: number;
}) {
  return (
    <Sheet>
      {Array.from({ length: count }, (_, index) => (
        <View key={index}>
          {index > 0 ? <SheetSeparator /> : null}
          <View style={[styles.row, { minHeight }]}>
            {thumb ? <Block width={thumb} height={thumb} round={radius.thumb} /> : null}
            <View style={styles.rowText}>
              <Block width="60%" height={14} />
              <Block width="40%" height={14} />
            </View>
          </View>
        </View>
      ))}
    </Sheet>
  );
}

/**
 * The shape of what is loading, shown only once a read has taken 180 ms, so
 * fast reads never flash it. Static on purpose: no shimmer, no pulse. Screens
 * show it only while loading with nothing on screen yet (`loading && data ===
 * null`); with data on screen they keep it.
 */
export function Skeleton({
  variant,
  rows = 6,
  thumb = 56,
  label = strings.a11y.loading,
}: SkeletonProps) {
  const visible = useDelayedFlag(true, delay.skeleton);
  if (!visible) return null;

  return (
    <View
      accessible
      accessibilityRole="progressbar"
      accessibilityLabel={label}
      accessibilityLiveRegion="polite"
      style={styles.frame}
    >
      {variant === 'list' ? <Block width={200} height={30} round={6} /> : null}
      {variant === 'list' || variant === 'rows' ? (
        <SkeletonRows
          count={rows}
          thumb={thumb}
          minHeight={thumb === 76 ? ROW_MIN_PHOTO : ROW_MIN}
        />
      ) : null}
      {variant === 'options' ? (
        <SkeletonRows count={8} thumb={null} minHeight={OPTION_MIN} />
      ) : null}
      {variant === 'detail' ? (
        <>
          <Block width={THUMB_DETAIL} height={THUMB_DETAIL} round={radius.thumb} />
          <Block width="70%" height={28} round={6} />
          <Outline height={120} round={radius.card} />
          <Outline height={56} round={radius.control} />
        </>
      ) : null}
      {variant === 'grid' ? (
        <View style={styles.grid}>
          {Array.from({ length: rows }, (_, index) => (
            <View key={index} style={styles.gridCell}>
              <Block width="100%" height={96} round={radius.sheet} />
            </View>
          ))}
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  frame: {
    gap: space.lg,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: ROW_GAP,
    paddingVertical: ROW_PADDING.vertical,
    paddingStart: ROW_PADDING.start,
    paddingEnd: ROW_PADDING.end,
  },
  rowText: {
    flex: 1,
    gap: space.sm,
  },
  outline: {
    borderWidth: 2,
  },
  grid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: space.md,
  },
  gridCell: {
    width: '47%',
    flexGrow: 1,
  },
});
