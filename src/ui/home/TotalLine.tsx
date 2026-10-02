import { StyleSheet, View } from 'react-native';

import { strings } from '@/i18n/strings';
import { AppText } from '@/ui/components/AppText';
import type { NameTotal } from '@/ui/home/homeList';
import { space } from '@/ui/theme';

export interface TotalLineProps {
  /** From `nameTotals`: names kept in two or more places. */
  totals: readonly NameTotal[];
}

function Total({ total }: { total: NameTotal }) {
  const none = total.quantity === 0;
  return (
    <AppText
      variant="meta"
      accessibilityLabel={
        none
          ? strings.search.totalNone(total.name, total.places)
          : strings.search.total(total.name, total.quantity, total.places)
      }
    >
      {strings.search.totalName(total.name)}{' '}
      <AppText variant="aside" tone={none ? 'signal' : 'ink'}>
        {none ? strings.quantity.noneLeftValue : strings.rows.times(total.quantity)}
      </AppText>{' '}
      {none ? strings.search.totalNoneIn(total.places) : strings.search.totalIn(total.places)}
    </AppText>
  );
}

/**
 * "“AA batteries”: ×14 in 2 places", above the matching rows.
 *
 * "Do we still have it?" has one answer even when it is kept in two boxes:
 * the rows say how many are in each, this line says how many there are.
 * Plain text, not a control (none of the drafts covered the split case).
 */
export function TotalLine({ totals }: TotalLineProps) {
  return (
    <View style={styles.lines}>
      {totals.map((total) => (
        <Total key={total.name.toLowerCase()} total={total} />
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  lines: {
    gap: space.xs,
  },
});
