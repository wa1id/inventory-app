import AsyncStorage from '@react-native-async-storage/async-storage';

const ONBOARDING_KEY = 'onboarding.completed.v1';

/**
 * Onboarding completion lives in AsyncStorage rather than the inventory
 * database: it is a device preference, not inventory, and it must be readable
 * before the database finishes migrating.
 */
export async function hasCompletedOnboarding(): Promise<boolean> {
  try {
    return (await AsyncStorage.getItem(ONBOARDING_KEY)) === 'true';
  } catch {
    // A preference we cannot read is not worth blocking launch over; showing
    // onboarding one extra time is the safer failure.
    return false;
  }
}

export async function setOnboardingCompleted(completed: boolean): Promise<void> {
  try {
    if (completed) {
      await AsyncStorage.setItem(ONBOARDING_KEY, 'true');
    } else {
      await AsyncStorage.removeItem(ONBOARDING_KEY);
    }
  } catch {
    // Non-fatal: worst case the user sees onboarding again next launch.
  }
}
