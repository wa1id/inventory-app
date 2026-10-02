import { ActionSheetIOS, Alert, Appearance, Platform } from 'react-native';

import { strings } from '@/i18n/strings';

export interface ConfirmOptions {
  /** A question: "Delete “Cordless drill”?" */
  title: string;
  /** The impact, and what stays: "This cannot be undone." */
  body: string;
  confirmLabel: string;
  /** Defaults to "Cancel"; a dirty form says "Keep editing". */
  cancelLabel?: string;
  /** Draws the confirm button as destructive. Default true: most confirms are deletes. */
  destructive?: boolean;
}

/**
 * Asks before something that cannot be taken back.
 *
 * Reserved for deletes, replacing or removing a label, restoring a backup,
 * leaving or importing into the household and discarding a dirty form. Moves,
 * files and adds use Undo instead, and quantities, names and edits neither.
 * Resolves false on Cancel and when the dialog is dismissed (Android back).
 */
export function confirm({
  title,
  body,
  confirmLabel,
  cancelLabel = strings.common.cancel,
  destructive = true,
}: ConfirmOptions): Promise<boolean> {
  return new Promise((resolve) => {
    Alert.alert(
      title,
      body,
      [
        { text: cancelLabel, style: 'cancel', onPress: () => resolve(false) },
        {
          text: confirmLabel,
          style: destructive ? 'destructive' : 'default',
          onPress: () => resolve(true),
        },
      ],
      { cancelable: true, onDismiss: () => resolve(false) },
    );
  });
}

export interface ActionSheetOption {
  label: string;
  destructive?: boolean;
  onPress: () => void;
}

/**
 * A short list of choices (photo options, label problems).
 *
 * The system action sheet on iOS. Android has none without a new native
 * module, so it is an alert, which fits at most two choices beside Cancel;
 * callers keep to that.
 */
export function showActionSheet({
  title,
  options,
  cancelLabel = strings.common.cancel,
}: {
  title?: string;
  options: readonly ActionSheetOption[];
  cancelLabel?: string;
}): void {
  if (Platform.OS === 'ios') {
    const destructive = options
      .map((option, index) => (option.destructive ? index : -1))
      .filter((index) => index >= 0);
    const scheme = Appearance.getColorScheme();
    ActionSheetIOS.showActionSheetWithOptions(
      {
        title,
        options: [...options.map((option) => option.label), cancelLabel],
        cancelButtonIndex: options.length,
        destructiveButtonIndex: destructive,
        userInterfaceStyle: scheme === 'dark' || scheme === 'light' ? scheme : undefined,
      },
      (index) => options[index]?.onPress(),
    );
    return;
  }

  Alert.alert(
    title ?? '',
    undefined,
    [
      ...options.slice(0, 2).map((option) => ({
        text: option.label,
        style: option.destructive ? ('destructive' as const) : ('default' as const),
        onPress: option.onPress,
      })),
      { text: cancelLabel, style: 'cancel' as const },
    ],
    { cancelable: true },
  );
}
