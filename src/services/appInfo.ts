import Constants from 'expo-constants';

/** App version shown in Settings and the privacy notice. */
export const appVersion: string = (Constants.expoConfig?.version as string | undefined) ?? '0.0.0';
