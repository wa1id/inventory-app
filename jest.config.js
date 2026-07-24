const aliases = {
  '^@/(.*)$': '<rootDir>/src/$1',
};

/**
 * Two suites with different needs:
 *
 * - `logic` runs in plain Node so persistence tests can drive real SQL through
 *   `node:sqlite`. `expo-crypto` is mapped to a Node-CSPRNG stub so ID and QR
 *   token generation runs its actual code path.
 * - `ui` uses the jest-expo preset for React Native component rendering.
 */
module.exports = {
  projects: [
    {
      displayName: 'logic',
      testEnvironment: 'node',
      testMatch: ['<rootDir>/src/**/__tests__/**/*.test.ts'],
      transform: {
        '^.+\\.[jt]sx?$': ['babel-jest', { presets: ['babel-preset-expo'] }],
      },
      // Expo ships ESM in node_modules; it has to go through Babel here
      // because this project runs in plain Node rather than the RN preset.
      transformIgnorePatterns: ['node_modules/(?!(expo|expo-.*|@expo|@expo/.*)/)'],
      globals: { __DEV__: false },
      moduleNameMapper: {
        ...aliases,
        '^expo-crypto$': '<rootDir>/src/testing/expoCryptoStub.ts',
      },
    },
    {
      displayName: 'ui',
      preset: 'jest-expo',
      testMatch: ['<rootDir>/**/__tests__/**/*.test.tsx'],
      moduleNameMapper: aliases,
      transformIgnorePatterns: [
        'node_modules/(?!((jest-)?react-native|@react-native(-community)?)|expo(nent)?|@expo(nent)?/.*|@expo-google-fonts/.*|react-navigation|@react-navigation/.*|@sentry/react-native|native-base|react-native-svg|react-native-qrcode-svg)',
      ],
    },
  ],
};
