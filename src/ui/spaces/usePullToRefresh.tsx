import { useState, type ReactElement } from 'react';
import { Platform, RefreshControl, type RefreshControlProps } from 'react-native';

import { useTheme } from '@/ui/theme';

/**
 * Pull-to-refresh for a list fed by `useInventoryQuery`.
 *
 * The spinner shows only for a pull the person made: the query also reloads
 * on every focus and after every write, and a spinner then would flicker on
 * each return to the screen. `loading` is whether any of the list's queries
 * are still reading; the pull ends when they all have.
 */
export function usePullToRefresh(
  loading: boolean,
  reload: () => void,
): ReactElement<RefreshControlProps> {
  const { colors } = useTheme();
  const [pulled, setPulled] = useState(false);

  // Derived state, as in `useInventoryQuery`: the pull is over once the reads
  // it started have settled.
  if (pulled && !loading) {
    setPulled(false);
  }

  return (
    <RefreshControl
      refreshing={pulled && loading}
      onRefresh={() => {
        setPulled(true);
        reload();
      }}
      tintColor={Platform.OS === 'ios' ? colors.graphite : undefined}
      colors={[colors.ink]}
      progressBackgroundColor={colors.sheet}
    />
  );
}
