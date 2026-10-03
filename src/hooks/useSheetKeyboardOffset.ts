import { useState } from 'react';
import { Platform, useWindowDimensions, type LayoutChangeEvent } from 'react-native';
import { useHeaderHeight } from 'expo-router/react-navigation';

/**
 * `keyboardVerticalOffset` for a form in a sheet. `formHeight` is 0 until
 * laid out; `floating` is a sheet that does not reach the bottom of the
 * screen (iPad).
 *
 * `KeyboardAvoidingView` pads its bottom by
 * `frame.y + frame.height - (keyboard.screenY - offset)`. Its frame is
 * measured from its parent, the keyboard's top from the top of the window,
 * so the offset has to be how far the parent's top is from the window's top.
 * The header height is that distance only on a pushed screen: an iPhone page
 * sheet starts below the status bar plus a gap (about 60 pt the header height
 * leaves out), and neither counts the connection banner above the form. So
 * the form is measured instead. A sheet form reaches the bottom of the window
 * (the modal frame pads only the sides, and the bottom bar is inside the
 * form), so its top is the window's height less its own. That holds on an
 * iPhone, and on Android, where edge-to-edge makes the window, its dimensions
 * and the keyboard's `screenY` all full-screen (React Native 0.86).
 *
 * Never below the header height: a wrong measurement can only lift the bar
 * higher, never leave it under the keyboard.
 */
export function sheetKeyboardOffset({
  headerHeight,
  windowHeight,
  formHeight,
  floating,
}: {
  headerHeight: number;
  windowHeight: number;
  formHeight: number;
  floating: boolean;
}): number {
  if (floating || formHeight <= 0) return headerHeight;
  return Math.max(headerHeight, windowHeight - formHeight);
}

/**
 * Keeps a sheet's bottom bar above the keyboard. Pass `keyboardVerticalOffset`
 * to the form's `KeyboardAvoidingView` (`behavior="padding"`) and `onLayout`
 * to that view, or to a wrapper it fills from the top. With padding the
 * view's own height stays the same while the keyboard is up, so the offset
 * does not move under it. Nothing in the sheets autofocuses on open, so the
 * form is measured before the keyboard first rises. Not checkable on the web.
 */
export function useSheetKeyboardOffset(): {
  keyboardVerticalOffset: number;
  onLayout: (event: LayoutChangeEvent) => void;
} {
  const headerHeight = useHeaderHeight();
  const { height: windowHeight } = useWindowDimensions();
  const [formHeight, setFormHeight] = useState(0);
  return {
    keyboardVerticalOffset: sheetKeyboardOffset({
      headerHeight,
      windowHeight,
      formHeight,
      // An iPad sheet sits clear of the bottom of the screen, so it keeps the header height.
      floating: Platform.OS === 'ios' && Platform.isPad,
    }),
    onLayout: (event) => setFormHeight(event.nativeEvent.layout.height),
  };
}
