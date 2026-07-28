const expoConfig = require('eslint-config-expo/flat');

module.exports = [
  ...expoConfig,
  {
    ignores: [
      'node_modules/**',
      'android/**',
      'ios/**',
      '.expo/**',
      'coverage/**',
      'dist/**',
      // Local git worktrees are checkouts of this same repo; linting them
      // double-reports every finding against a copy nobody is editing.
      '.claude/worktrees/**',
    ],
  },
];
