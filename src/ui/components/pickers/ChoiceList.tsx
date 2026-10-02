import { Fragment, type ReactNode } from 'react';
import { View } from 'react-native';

import { AppText } from '@/ui/components/AppText';
import { Icon } from '@/ui/components/Icon';
import { Row } from '@/ui/components/Row';
import { Sheet, SheetSeparator } from '@/ui/components/Sheet';
import { haptics } from '@/ui/haptics';
import { OPTION_MIN, useTheme } from '@/ui/theme';

export interface ChoiceOption<T extends string> {
  value: T;
  title: string;
  subtitle?: string;
  leading?: ReactNode;
  testID?: string;
}

export interface ChoiceListProps<T extends string> {
  options: readonly ChoiceOption<T>[];
  value: T;
  onChange: (value: T) => void;
  accessibilityLabel: string;
}

/**
 * A single choice from a short list, as rows in a sheet (the space of a
 * container, for instance). Every option is visible at once, unlike the old
 * horizontal chips that hid choices off screen.
 */
export function ChoiceList<T extends string>({
  options,
  value,
  onChange,
  accessibilityLabel,
}: ChoiceListProps<T>) {
  const { colors } = useTheme();

  return (
    <View accessibilityRole="radiogroup" accessibilityLabel={accessibilityLabel}>
      <Sheet>
        {options.map((option, index) => {
          const selected = option.value === value;
          return (
            <Fragment key={option.value}>
              {index > 0 ? <SheetSeparator /> : null}
              <Row
                onPress={() => {
                  if (selected) return;
                  haptics.choice();
                  onChange(option.value);
                }}
                leading={option.leading}
                aside={selected ? <Icon name="check" size={20} color={colors.ink} /> : null}
                selected={selected}
                minHeight={OPTION_MIN}
                accessibilityRole="radio"
                accessibilityLabel={
                  option.subtitle ? `${option.title}, ${option.subtitle}` : option.title
                }
                testID={option.testID}
              >
                <AppText variant="name">{option.title}</AppText>
                {option.subtitle ? (
                  <AppText variant="meta" tone="graphite">
                    {option.subtitle}
                  </AppText>
                ) : null}
              </Row>
            </Fragment>
          );
        })}
      </Sheet>
    </View>
  );
}
