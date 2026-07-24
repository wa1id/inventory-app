const expoConfig = require('eslint-config-expo/flat');

module.exports = [
  ...expoConfig,
  {
    ignores: ['node_modules/**', 'android/**', 'ios/**', '.expo/**', 'coverage/**', 'dist/**'],
  },
];
