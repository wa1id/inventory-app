const aliases = {
  '^@/(.*)$': '<rootDir>/src/$1',
};

/**
 * Agent worktrees live under `.claude/worktrees/`, each a full checkout of
 * another branch. Left visible, the `ui` project's `<rootDir>/**` glob collects
 * their test files and runs them against *this* tree's source through the `@/`
 * alias — so an unrelated branch's stale expectations fail a run of this one.
 * Ignoring the path for both test discovery and Haste also silences the
 * duplicate-package warnings those checkouts produce.
 */
const worktrees = '<rootDir>/.claude/';

/**
 * Two suites with different needs:
 *
 * - `logic` runs in plain Node so persistence tests can drive real SQL through
 *   `node:sqlite`. IDs use an injected Node CSPRNG (`setupLogic.ts`).
 *   `expo-crypto` is still mapped for account hashing and backup tests.
 * - `ui` uses the jest-expo preset for React Native component rendering.
 */
module.exports = {
  projects: [
    {
      displayName: 'logic',
      testEnvironment: 'node',
      testMatch: ['<rootDir>/src/**/__tests__/**/*.test.ts'],
      testPathIgnorePatterns: ['/node_modules/', worktrees],
      modulePathIgnorePatterns: [worktrees],
      transform: {
        '^.+\\.[jt]sx?$': ['babel-jest', { presets: ['babel-preset-expo'] }],
      },
      // Expo ships ESM in node_modules; it has to go through Babel here
      // because this project runs in plain Node rather than the RN preset.
      transformIgnorePatterns: ['node_modules/(?!(expo|expo-.*|@expo|@expo/.*)/)'],
      globals: { __DEV__: false },
      setupFilesAfterEnv: ['<rootDir>/src/testing/setupLogic.ts'],
      moduleNameMapper: {
        ...aliases,
        '^expo-crypto$': '<rootDir>/src/testing/expoCryptoStub.ts',
      },
    },
    {
      displayName: 'ui',
      preset: 'jest-expo',
      testMatch: ['<rootDir>/**/__tests__/**/*.test.tsx'],
      testPathIgnorePatterns: ['/node_modules/', worktrees],
      modulePathIgnorePatterns: [worktrees],
      moduleNameMapper: aliases,
      transformIgnorePatterns: [
        'node_modules/(?!((jest-)?react-native|@react-native(-community)?)|expo(nent)?|@expo(nent)?/.*|@expo-google-fonts/.*|react-navigation|@react-navigation/.*|@sentry/react-native|native-base|react-native-svg|react-native-qrcode-svg)',
      ],
    },
  ],
};
