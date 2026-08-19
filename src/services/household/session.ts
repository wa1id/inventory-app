import * as SecureStore from 'expo-secure-store';

import type { HouseholdSession } from './client';

const SESSION_KEY = 'household.session.v1';

export async function loadHouseholdSession(): Promise<HouseholdSession | null> {
  try {
    const stored = await SecureStore.getItemAsync(SESSION_KEY);
    if (!stored) return null;
    const parsed = JSON.parse(stored) as Partial<HouseholdSession>;
    if (
      typeof parsed.origin !== 'string' ||
      typeof parsed.token !== 'string' ||
      typeof parsed.deviceId !== 'string'
    ) {
      return null;
    }
    return {
      origin: parsed.origin,
      token: parsed.token,
      deviceId: parsed.deviceId,
      deviceName: typeof parsed.deviceName === 'string' ? parsed.deviceName : 'This phone',
      householdName: typeof parsed.householdName === 'string' ? parsed.householdName : 'Home',
    };
  } catch {
    return null;
  }
}

export async function saveHouseholdSession(session: HouseholdSession): Promise<void> {
  await SecureStore.setItemAsync(SESSION_KEY, JSON.stringify(session));
}

export async function clearHouseholdSession(): Promise<void> {
  try {
    await SecureStore.deleteItemAsync(SESSION_KEY);
  } catch {
    // A missing key is the outcome we wanted.
  }
}
